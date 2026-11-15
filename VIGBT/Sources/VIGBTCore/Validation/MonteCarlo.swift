import Foundation

/// Deterministic, seedable RNG (SplitMix64) so Monte Carlo runs are reproducible on every platform.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func uniform(_ a: Double, _ b: Double) -> Double { Double.random(in: a..<b, using: &self) }

    /// Standard normal via Box–Muller.
    public mutating func normal(_ mean: Double = 0, _ sigma: Double = 1) -> Double {
        let u1 = max(1e-12, Double.random(in: 0..<1, using: &self))
        let u2 = Double.random(in: 0..<1, using: &self)
        return mean + sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// How the club met the ball. Weights are a mid-handicap mix (SPEC §12).
public enum StrikeType: String, CaseIterable, Sendable {
    case pure, slice, hook, push, pull, thinSkull, fat, toeHeel, topped, shank, popUp

    public var weight: Double {
        switch self {
        case .pure: return 0.40
        case .slice: return 0.15
        case .hook: return 0.08
        case .push, .pull, .fat, .toeHeel: return 0.06
        case .thinSkull: return 0.08
        case .topped: return 0.03
        case .shank, .popUp: return 0.01
        }
    }
}

public struct MonteCarloConfig: Sendable {
    public var shots: Int = 1_000
    public var seed: UInt64 = 1
    public var maxFrames: Int = 40
    public var minRadiusPixels: Double = 1.0
    public var dropout: Double = 0.05
    public var centroidSigma: Double = 0.35
    public var radiusSigma: Double = 0.2
    public var radiusSigmaFraction: Double = 0.03
    public var teeDepthSigma: Double = 0.02
    public var poseSigmaDeg: Double = 0.5
    public var headingSigmaDeg: Double = 3
    public var useReprojectionFit: Bool = true
    /// The golfer enters wind (strength preset + 8 directions, judged with ±40% / ±30° error).
    public var windInput: Bool = false
    public var headingMode: HeadingMode = .raw
    /// Shots per tripod setup in `.session` mode.
    public var sessionSize: Int = 8

    public enum HeadingMode: String, Sendable {
        /// Compass as measured (±`headingSigmaDeg`).
        case raw
        /// Flag sighted at setup: only the GPS bearing error of the tee→flag line remains.
        case sighted
        /// `SessionCompassLearner` corrects the compass from found balls of the same setup.
        case session
    }

    public init() {}
}

public struct MonteCarloReport: Sendable {
    public struct Group: Sendable {
        public var count: Int
        public var tracked: Int
        public var medianErrorYards: Double
        public var p90ErrorYards: Double
    }

    public var shots: Int
    public var tracked: Int
    public var medianFramesFollowed: Double
    /// Distance from the predicted target to the true rest position, yards (sorted).
    public var errorsYards: [Double]
    /// Share of balls whose rest lies inside the estimator's search ellipse (current policy).
    public var coverageEllipse: Double
    /// Share inside the old policy: circle of 8% of carry around the *landing* point.
    public var coverageLegacyCircle: Double
    public var speedErrorP90Mph: Double
    public var tiltErrorP90Deg: Double
    public var byStrike: [StrikeType: Group]

    public var trackedFraction: Double { shots == 0 ? 0 : Double(tracked) / Double(shots) }
    public var medianErrorYards: Double { Self.percentile(errorsYards, 50) }
    public var p80ErrorYards: Double { Self.percentile(errorsYards, 80) }
    public var p90ErrorYards: Double { Self.percentile(errorsYards, 90) }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let i = min(sorted.count - 1, max(0, Int((p / 100 * Double(sorted.count - 1)).rounded())))
        return sorted[i]
    }

    public var summary: String {
        func f(_ x: Double) -> String { String(Int(x.rounded())) }
        var lines = [
            "VIGBT Monte Carlo: \(shots) shots, tracked \(f(trackedFraction * 100))%, median frames followed \(f(medianFramesFollowed))",
            "Error to final rest (yd): median \(f(medianErrorYards)), p80 \(f(p80ErrorYards)), p90 \(f(p90ErrorYards))",
            "Search coverage: ellipse around predicted rest \(f(coverageEllipse * 100))% | legacy 8% circle at landing \(f(coverageLegacyCircle * 100))%",
            "Launch speed error p90 \(String(format: "%.1f", speedErrorP90Mph)) mph; spin-axis tilt error p90 \(f(tiltErrorP90Deg))°",
        ]
        for s in StrikeType.allCases {
            guard let g = byStrike[s], g.count > 0 else { continue }
            lines.append("  \(s.rawValue): \(g.count) shots, tracked \(f(Double(g.tracked) / Double(g.count) * 100))%, "
                         + "median \(f(g.medianErrorYards)) yd, p90 \(f(g.p90ErrorYards)) yd")
        }
        return lines.joined(separator: "\n")
    }
}

/// End-to-end validation (SPEC §12): random strikes → true flight with unknown wind, spin and ground →
/// 120 fps camera observation until the ball is lost → the real VIGBT pipeline → error to the true rest.
/// Mirrors `tools/monte_carlo.py`, which runs the same model vectorised for million-shot studies.
public enum MonteCarlo {
    struct Club {
        var spinCategory: VIGBTCore.Club
        var weight: Double
        var speedMph: ClosedRange<Double>
        var launchDeg: ClosedRange<Double>
        var spinRpm: ClosedRange<Double>
    }

    static let clubs = [
        Club(spinCategory: .driver, weight: 0.35, speedMph: 125...155, launchDeg: 10...15, spinRpm: 2500...3500),
        Club(spinCategory: .midIron, weight: 0.40, speedMph: 95...120, launchDeg: 15...20, spinRpm: 5500...7500),
        Club(spinCategory: .wedge, weight: 0.25, speedMph: 75...100, launchDeg: 22...28, spinRpm: 7500...9500),
    ]

    public static func run(_ config: MonteCarloConfig) -> MonteCarloReport {
        var rng = SeededRandom(seed: config.seed)
        var errors: [Double] = []
        var frames: [Double] = []
        var speedErr: [Double] = []
        var tiltErr: [Double] = []
        var inEllipse = 0, inLegacy = 0, tracked = 0
        var perStrike: [StrikeType: (count: Int, tracked: Int, errors: [Double])] = [:]
        var compass = CompassState()

        for i in 0..<config.shots {
            if i % max(1, config.sessionSize) == 0 {
                compass = CompassState(sessionErrorDeg: rng.normal(0, config.headingSigmaDeg))
            }
            let shot = simulateOne(config, &rng, &compass)
            perStrike[shot.strike, default: (0, 0, [])].count += 1
            frames.append(Double(shot.framesFollowed))
            guard let e = shot.errorMeters else { continue }
            tracked += 1
            let yd = Units.yards(fromMeters: e)
            errors.append(yd)
            perStrike[shot.strike]!.tracked += 1
            perStrike[shot.strike]!.errors.append(yd)
            if shot.insideEllipse { inEllipse += 1 }
            if shot.insideLegacy { inLegacy += 1 }
            if let s = shot.speedErrorMph { speedErr.append(abs(s)) }
            if let t = shot.tiltErrorDeg { tiltErr.append(abs(t)) }
        }
        let groups = perStrike.mapValues { v -> MonteCarloReport.Group in
            let s = v.errors.sorted()
            return .init(count: v.count, tracked: v.tracked,
                         medianErrorYards: MonteCarloReport.percentile(s, 50), p90ErrorYards: MonteCarloReport.percentile(s, 90))
        }
        let t = Double(max(1, tracked))
        return MonteCarloReport(shots: config.shots, tracked: tracked,
                                medianFramesFollowed: MonteCarloReport.percentile(frames.sorted(), 50),
                                errorsYards: errors.sorted(), coverageEllipse: Double(inEllipse) / t,
                                coverageLegacyCircle: Double(inLegacy) / t,
                                speedErrorP90Mph: MonteCarloReport.percentile(speedErr.sorted(), 90),
                                tiltErrorP90Deg: MonteCarloReport.percentile(tiltErr.sorted(), 90),
                                byStrike: groups)
    }

    struct ShotOutcome {
        var strike: StrikeType
        var framesFollowed: Int
        var errorMeters: Double?
        var insideEllipse = false
        var insideLegacy = false
        var speedErrorMph: Double?
        var tiltErrorDeg: Double?
    }

    static func pick<T>(_ items: [T], weight: (T) -> Double, _ rng: inout SeededRandom) -> T {
        let total = items.reduce(0) { $0 + weight($1) }
        var x = rng.uniform(0, total)
        for i in items {
            x -= weight(i)
            if x <= 0 { return i }
        }
        return items[items.count - 1]
    }

    /// Compass state shared by the shots of one tripod setup.
    struct CompassState {
        var sessionErrorDeg: Double = 0
        var learner = SessionCompassLearner()
    }

    static func simulateOne(_ cfg: MonteCarloConfig, _ rng: inout SeededRandom, _ compass: inout CompassState) -> ShotOutcome {
        // 1. Strike.
        let club = pick(clubs, weight: { $0.weight }, &rng)
        let strike = pick(StrikeType.allCases, weight: { $0.weight }, &rng)
        var speed = rng.uniform(club.speedMph.lowerBound, club.speedMph.upperBound) * Units.metersPerSecondPerMph
        var launch = rng.uniform(club.launchDeg.lowerBound, club.launchDeg.upperBound)
        var spin = rng.uniform(club.spinRpm.lowerBound, club.spinRpm.upperBound)
        var tilt = rng.normal(0, 5)
        var az = rng.normal(0, 2)
        switch strike {
        case .pure: break
        case .slice: tilt += rng.uniform(15, 35); az += rng.uniform(0, 4); spin *= 1.1
        case .hook: tilt -= rng.uniform(15, 35); az -= rng.uniform(0, 4)
        case .push: az += rng.uniform(4, 10)
        case .pull: az -= rng.uniform(4, 10)
        case .thinSkull: launch *= rng.uniform(0.4, 0.7); spin *= rng.uniform(0.4, 0.65); speed *= rng.uniform(0.93, 1.0)
        case .fat: speed *= rng.uniform(0.5, 0.75); launch += rng.uniform(0, 3); spin *= rng.uniform(0.7, 0.9)
        case .toeHeel: speed *= rng.uniform(0.88, 0.95); tilt += (rng.uniform(0, 1) < 0.5 ? -1 : 1) * rng.uniform(8, 20)
        case .topped: launch = rng.uniform(-3, 3); speed *= rng.uniform(0.4, 0.7); spin = rng.uniform(500, 1500)
        case .shank: az += rng.uniform(35, 60); speed *= rng.uniform(0.5, 0.7)
        case .popUp: launch = rng.uniform(30, 45); speed *= rng.uniform(0.6, 0.8); spin *= 1.6
        }
        let trueLaunch = LaunchVector(ballSpeed: speed, launchAngleDeg: launch, azimuthDeg: az)
        let trueSpin = SpinEstimate(rpm: spin, axisTiltDeg: tilt)

        // 2. Conditions the app does not know.
        let windDir = rng.uniform(0, 2 * .pi), windSpeed = rng.uniform(0, 6)
        let wind = Vector3(windSpeed * cos(windDir), windSpeed * sin(windDir), 0)
        // The air the ball flies through gusts ±20% around the base wind the golfer feels.
        let flightWind = wind * rng.normal(1, 0.2)
        // What the golfer reports: strength judged ×0.6–1.4 then snapped to a preset; direction ±30° then
        // snapped to one of 8. (Camera heading is 0 here, so the physics frame is the target frame.)
        let judgedMph = Units.mph(fromMetersPerSecond: windSpeed) * rng.uniform(0.6, 1.4)
        let preset = WindStrength.allCases.min { abs($0.mph - judgedMph) < abs($1.mph - judgedMph) } ?? .calm
        let towardDeg = (Units.degrees(windDir) + rng.uniform(-30, 30))
        let towardSnapped = (towardDeg / 45).rounded() * 45
        let userSpeed = Units.metersPerSecond(fromMph: preset.mph)
        let userWind = Vector3(userSpeed * cos(Units.radians(towardSnapped)), userSpeed * sin(Units.radians(towardSnapped)), 0)
        var air = AerodynamicModel()
        air.airDensity = rng.uniform(1.12, 1.25)
        let ground = GroundModel(restitution: rng.uniform(0.25, 0.45), bounceFriction: rng.uniform(0.4, 0.6),
                                 rollingFriction: rng.uniform(0.15, 0.4))

        // 3. Truth: flight, then bounce and roll.
        let truth = BallisticSolver(model: air).solve(launch: trueLaunch, spin: trueSpin, wind: flightWind)
        let landV = truth.samples.last?.velocity ?? .zero
        let rest = RollModel.rest(landing: Vector3(truth.carryMeters, -truth.lateralMeters, 0), velocity: landV, ground: ground)

        // 4. Camera: down-the-line tripod, randomised placement.
        let dist = rng.uniform(2.5, 4.0), height = rng.uniform(0.8, 1.4), lat = rng.uniform(-0.4, 0.4)
        let teeWorld = Vector3(dist, -lat, -height)
        let trueCal = TeeCalibration(distanceToTeeMeters: 1, cameraPitchRadians: -atan2(height, dist),
                                     cameraRollRadians: Units.radians(rng.normal(0, 1)), cameraHeadingDeg: 0,
                                     horizontalFOVRadians: Units.radians(108), teeLocation: GeoCoordinate(latitude: 0, longitude: 0))
        let teeProj = LaunchVectorExtractor.project(teeWorld, calibration: trueCal)
        let f = trueCal.focalLengthPixels
        let early = BallisticSolver(model: air, timeStep: 1 / 120, maxFlightSeconds: Double(cfg.maxFrames) / 120 + 0.001,
                                    sampleStride: 1).solve(launch: trueLaunch, spin: trueSpin, wind: flightWind)
        var obs: [TrackedCentroid] = []
        var followed = 0
        for k in 1...cfg.maxFrames {
            guard k < early.samples.count else { break }
            let s = early.samples[k]
            guard abs(s.time - Double(k) / 120) < 1e-6 else { break } // landing sample: ball on the ground
            let q = LaunchVectorExtractor.project(teeWorld + s.position, calibration: trueCal)
            let r = f * air.ballRadiusMeters / q.z
            let visible = q.z > 0.3 && q.x > 4 && q.x < trueCal.imageWidth - 4 && q.y > 4 && q.y < trueCal.imageHeight - 4
                && r >= cfg.minRadiusPixels
            guard visible else { break } // the camera has lost the ball
            followed += 1
            if rng.uniform(0, 1) < cfg.dropout { continue }
            let rm = max(0.3, r + rng.normal(0, cfg.radiusSigma + cfg.radiusSigmaFraction * r))
            obs.append(TrackedCentroid(frameOffset: k, x: q.x + rng.normal(0, cfg.centroidSigma),
                                       y: q.y + rng.normal(0, cfg.centroidSigma), radiusPixels: rm, score: 1))
        }
        var outcome = ShotOutcome(strike: strike, framesFollowed: followed)

        // 5. What the app believes: calibration with LiDAR / IMU / compass errors.
        var cal = trueCal
        cal.distanceToTeeMeters = teeProj.z + rng.normal(0, cfg.teeDepthSigma)
        cal.cameraPitchRadians += Units.radians(rng.normal(0, cfg.poseSigmaDeg))
        cal.cameraRollRadians += Units.radians(rng.normal(0, cfg.poseSigmaDeg))
        let refR = f * air.ballRadiusMeters / teeProj.z + rng.normal(0, cfg.radiusSigma / 6.0.squareRoot())
        let teePixel = (teeProj.x + rng.normal(0, cfg.centroidSigma / 2), teeProj.y + rng.normal(0, cfg.centroidSigma / 2))
        // Compass error left after correction (degrees), and the correction applied.
        var applied = 0.0
        let heading: Double
        switch cfg.headingMode {
        case .raw:
            heading = rng.normal(0, cfg.headingSigmaDeg)
        case .sighted:
            let flag = rng.uniform(100, 220)
            heading = rng.normal(0, Units.degrees(atan(3 * 2.0.squareRoot() / flag))) + rng.normal(0, 0.5)
        case .session:
            applied = compass.learner.errorDeg
            heading = compass.sessionErrorDeg - applied
        }
        let compassCorrected = cfg.headingMode == .sighted || (cfg.headingMode == .session && compass.learner.isCorrected)

        // 6. The VIGBT pipeline.
        guard var est = try? LaunchVectorExtractor().extract(centroids: obs, calibration: cal, referenceRadiusPixels: refR),
              est.ballSpeed.isFinite, est.ballSpeed > 3 else { return outcome }
        let prior = SpinEstimator.estimate(club: club.spinCategory, launchAngleDeg: est.launchAngleDeg).rpm
        var estSpin = SpinEstimate(rpm: prior)
        if cfg.useReprojectionFit,
           let fit = ReprojectionFitter().fit(centroids: obs, tee: teePixel, calibration: cal, initial: est, spinPrior: prior) {
            est = fit.launch
            estSpin = fit.spin
        }
        guard est.launchAngleDeg > -5 else { return outcome }
        var estimator = LandingZoneEstimator()
        estimator.compassAndWindCorrected = cfg.windInput && compassCorrected
        let landing = estimator.estimate(launch: est, calibration: cal, spin: estSpin,
                                         wind: cfg.windInput ? userWind : .zero).landing

        // 7. Score against the true rest, after the compass error rotates the prediction.
        let h = Units.radians(heading)
        func rotated(_ carry: Double, _ right: Double) -> (Double, Double) {
            (carry * cos(h) - right * sin(h), carry * sin(h) + right * cos(h))
        }
        let (pa, pr) = rotated(landing.restCarry, landing.restLateral)
        let (ta, tr) = (rest.x, -rest.y)
        let err = ((pa - ta) * (pa - ta) + (pr - tr) * (pr - tr)).squareRoot()
        outcome.errorMeters = err
        // Ellipse aligned with the predicted direction.
        let d = max(1e-9, (pa * pa + pr * pr).squareRoot())
        let ua = pa / d, ur = pr / d
        let along = (ta - pa) * ua + (tr - pr) * ur
        let across = -(ta - pa) * ur + (tr - pr) * ua
        let A = landing.searchAlongMeters ?? landing.searchRadiusMeters
        let L = landing.searchLateralMeters ?? landing.searchRadiusMeters
        outcome.insideEllipse = (along / A) * (along / A) + (across / L) * (across / L) <= 1
        let (la, lr) = rotated(landing.carryMeters, landing.lateralMeters)
        outcome.insideLegacy = ((la - ta) * (la - ta) + (lr - tr) * (lr - tr)).squareRoot() <= max(5, 0.08 * landing.carryMeters)
        // Session mode: the golfer finds the ball, which teaches the learner this setup's compass error.
        // Local frame → GPS: camera heading 0 = north, so forward = north and right = east.
        if cfg.headingMode == .session {
            let origin = GeoCoordinate(latitude: 0, longitude: 0)
            let predicted = GeoMath.coordinate(east: pr, north: pa, from: origin)
            let found = GeoMath.coordinate(east: tr, north: ta, from: origin)
            compass.learner.recordFoundBall(tee: origin, predicted: predicted, found: found, appliedErrorDeg: applied)
        }
        outcome.speedErrorMph = Units.mph(fromMetersPerSecond: est.ballSpeed - trueLaunch.ballSpeed)
        outcome.tiltErrorDeg = estSpin.axisTiltDeg - trueSpin.axisTiltDeg
        return outcome
    }
}
