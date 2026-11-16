import XCTest
@testable import VIGBTCore

/// CI-sized slice of the Monte Carlo validation (SPEC §12). Bounds are deliberately looser than the
/// million-shot results (median 14.3 yd, p90 37.5 yd, ellipse coverage 84.6%) to tolerate a small sample.
final class MonteCarloTests: XCTestCase {
    private func run(shots: Int = 400, fit: Bool = true) -> MonteCarloReport {
        var c = MonteCarloConfig()
        c.shots = shots
        c.seed = 42
        c.useReprojectionFit = fit
        return MonteCarlo.run(c)
    }

    func testPipelineMeetsAccuracyTargets() {
        let r = run()
        print(r.summary)
        XCTAssertGreaterThan(r.trackedFraction, 0.95)
        XCTAssertGreaterThan(r.medianFramesFollowed, 15, "camera should follow the ball for well over 0.1 s")
        XCTAssertLessThan(r.medianErrorYards, 22)
        XCTAssertLessThan(r.p90ErrorYards, 55)
        XCTAssertLessThan(r.speedErrorP90Mph, 8)
        XCTAssertGreaterThan(r.coverageEllipse, 0.65)
        XCTAssertGreaterThan(r.coverageEllipse, r.coverageLegacyCircle + 0.3,
                             "rest-point ellipse must clearly beat the old 8% landing circle")
    }

    func testReprojectionFitBeatsPerFrameDepth() {
        let fitted = run(shots: 250, fit: true)
        let legacy = run(shots: 250, fit: false)
        XCTAssertLessThan(fitted.speedErrorP90Mph, legacy.speedErrorP90Mph)
        XCTAssertLessThan(fitted.p90ErrorYards, legacy.p90ErrorYards)
    }

    func testReproducibleForAGivenSeed() {
        XCTAssertEqual(run(shots: 50).errorsYards, run(shots: 50).errorsYards)
    }

    func testRollCarriesBallPastLanding() {
        let rest = RollModel.rest(landing: Vector3(200, 0, 0), velocity: Vector3(23, 0, -19))
        XCTAssertGreaterThan(rest.x, 210, "driver-like landing rolls on")
        XCTAssertLessThan(rest.x, 240)
        let wedge = RollModel.rest(landing: Vector3(100, 0, 0), velocity: Vector3(9, 0, -17))
        XCTAssertLessThan(wedge.x - 100, 3, "steep wedge landing barely rolls")
    }

    func testFitterRecoversSliceAxisFromCurvature() throws {
        // Noise-free track of a slice: the fit must find the tilt the club table cannot know.
        let cal = TeeCalibration(distanceToTeeMeters: 1, cameraPitchRadians: -atan2(1.1, 3.0), cameraHeadingDeg: 0,
                                 horizontalFOVRadians: Units.radians(108), teeLocation: GeoCoordinate(latitude: 0, longitude: 0))
        let tee = Vector3(3.0, -0.2, -1.1)
        let launch = LaunchVector(ballSpeed: 62, launchAngleDeg: 13, azimuthDeg: 1)
        let spin = SpinEstimate(rpm: 3000, axisTiltDeg: 25)
        let early = BallisticSolver(timeStep: 1 / 120, maxFlightSeconds: 0.3, sampleStride: 1).solve(launch: launch, spin: spin)
        let f = cal.focalLengthPixels
        var obs: [TrackedCentroid] = []
        for k in 1..<min(36, early.samples.count) {
            let q = LaunchVectorExtractor.project(tee + early.samples[k].position, calibration: cal)
            obs.append(TrackedCentroid(frameOffset: k, x: q.x, y: q.y, radiusPixels: f * 0.021335 / q.z, score: 1))
        }
        let tp = LaunchVectorExtractor.project(tee, calibration: cal)
        var c = cal
        c.distanceToTeeMeters = tp.z
        let initial = try LaunchVectorExtractor().extract(centroids: obs, calibration: c, referenceRadiusPixels: f * 0.021335 / tp.z)
        let fit = try XCTUnwrap(ReprojectionFitter().fit(centroids: obs, tee: (tp.x, tp.y), calibration: c,
                                                         initial: initial, spinPrior: 2700))
        XCTAssertEqual(fit.launch.ballSpeed, 62, accuracy: 0.5)
        XCTAssertEqual(fit.launch.launchAngleDeg, 13, accuracy: 0.5)
        XCTAssertEqual(fit.spin.axisTiltDeg, 25, accuracy: 6)
    }
}

/// Wind input and compass correction (SPEC §12.5).
final class WindCompassTests: XCTestCase {
    func testWindVectorAndHeadwind() {
        // Target due north (camera heading 0): wind "into you" comes from the north and blows south.
        let into = WindInput(strength: .moderate, direction: .into, targetBearingDeg: 0)
        let v = into.vector(cameraHeadingDeg: 0)
        XCTAssertEqual(v.x, -Units.metersPerSecond(fromMph: 10), accuracy: 1e-9, "against the ball")
        XCTAssertEqual(v.y, 0, accuracy: 1e-9)
        XCTAssertEqual(into.headwindMph(shotBearingDeg: 0), 10, accuracy: 1e-9)
        XCTAssertEqual(into.headwindMph(shotBearingDeg: 180), -10, accuracy: 1e-9, "helping when hitting the other way")

        // From the right blows the ball left (+y in the physics frame).
        let right = WindInput(strength: .strong, direction: .fromRight, targetBearingDeg: 90)
        XCTAssertEqual(right.fromBearingDeg, 180, accuracy: 1e-9)
        let vr = right.vector(cameraHeadingDeg: 90)
        XCTAssertEqual(vr.x, 0, accuracy: 1e-9)
        XCTAssertEqual(vr.y, Units.metersPerSecond(fromMph: 15), accuracy: 1e-9)
        XCTAssertEqual(right.description(targetBearingDeg: 90), "Wind strong (15 mph), from the right.")
    }

    func testWindChangesPredictionTheRightWay() {
        let cal = TeeCalibration(distanceToTeeMeters: 3, cameraPitchRadians: 0, cameraHeadingDeg: 0,
                                 horizontalFOVRadians: 1.9, teeLocation: GeoCoordinate(latitude: 0, longitude: 0))
        let launch = LaunchVector(ballSpeed: 60, launchAngleDeg: 12, azimuthDeg: 0)
        let e = LandingZoneEstimator()
        let calm = e.estimate(launch: launch, calibration: cal).landing
        let into = e.estimate(launch: launch, calibration: cal,
                              wind: WindInput(strength: .strong, direction: .into, targetBearingDeg: 0).vector(cameraHeadingDeg: 0)).landing
        let fromLeft = e.estimate(launch: launch, calibration: cal,
                                  wind: WindInput(strength: .strong, direction: .fromLeft, targetBearingDeg: 0).vector(cameraHeadingDeg: 0)).landing
        XCTAssertLessThan(into.carryMeters, calm.carryMeters)
        XCTAssertGreaterThan(fromLeft.lateralMeters, calm.lateralMeters + 3, "wind from the left pushes the ball right")
    }

    func testStaleWindIsIgnored() {
        let w = WindInput(strength: .light, direction: .helping, targetBearingDeg: 0, enteredAt: Date(timeIntervalSinceNow: -3 * 3600))
        XCTAssertTrue(w.isStale())
    }

    func testCircularStatistics() throws {
        XCTAssertEqual(Units.signedAngle(try XCTUnwrap(CompassCorrection.circularMean([358, 2, 0]))), 0, accuracy: 1e-6)
        XCTAssertLessThan(CompassCorrection.circularSpread([358, 2, 0, 1, 359]), 2)
        XCTAssertGreaterThan(CompassCorrection.circularSpread([0, 20, 340, 10]), CompassCorrection.maxSpreadDeg)
    }

    func testSightingMeasuresCompassError() {
        let tee = GeoCoordinate(latitude: 40, longitude: -75)
        let flag = GeoMath.destination(from: tee, distanceMeters: 160, bearingDeg: 30)
        XCTAssertEqual(CompassCorrection.sightingError(sightedHeadingDeg: 34, tee: tee, flag: flag), 4, accuracy: 0.01)
        var l = SessionCompassLearner()
        l.addSighting(errorDeg: 4)
        XCTAssertTrue(l.isCorrected)
        XCTAssertEqual(l.errorDeg, 3, accuracy: 1e-9, "weight 3 against shrinkage 1")
        XCTAssertEqual(l.corrected(34), 31, accuracy: 1e-9)
    }

    func testLearnerConvergesOnSetupError() {
        // Compass reads 5° high. Each found ball is ~5° anticlockwise of the prediction, plus noise.
        let tee = GeoCoordinate(latitude: 51, longitude: 0)
        var l = SessionCompassLearner()
        var rng = SeededRandom(seed: 3)
        for _ in 0..<8 {
            let trueBearing = rng.uniform(-10, 10)
            let applied = l.errorDeg
            let predicted = GeoMath.destination(from: tee, distanceMeters: 150, bearingDeg: trueBearing + 5 - applied)
            let found = GeoMath.destination(from: tee, distanceMeters: 150, bearingDeg: trueBearing + rng.normal(0, 2))
            l.recordFoundBall(tee: tee, predicted: predicted, found: found, appliedErrorDeg: applied)
        }
        XCTAssertEqual(l.errorDeg, 5, accuracy: 1.5)
        // Short shots are ignored.
        var short = SessionCompassLearner()
        short.recordFoundBall(tee: tee, predicted: GeoMath.destination(from: tee, distanceMeters: 20, bearingDeg: 5),
                              found: GeoMath.destination(from: tee, distanceMeters: 20, bearingDeg: 0), appliedErrorDeg: 0)
        XCTAssertFalse(short.isCorrected)
    }

    func testCorrectionsImproveMonteCarlo() {
        var base = MonteCarloConfig()
        base.shots = 400
        base.seed = 9
        var both = base
        both.windInput = true
        both.headingMode = .session
        let a = MonteCarlo.run(base), b = MonteCarlo.run(both)
        print(b.summary)
        XCTAssertLessThan(b.medianErrorYards, a.medianErrorYards)
        XCTAssertGreaterThan(b.coverageEllipse, 0.75, "tighter ellipse still covers most balls")
    }
}

/// Learning ground firmness from found balls (SPEC §12.6).
final class RollLearnerTests: XCTestCase {
    func testLearnsFirmerGround() {
        var l = RollLearner()
        XCTAssertEqual(l.multiplier, 1, accuracy: 1e-12)
        // Balls keep rolling 1.5× as far as the nominal model predicts.
        for _ in 0..<6 {
            l.record(landing: (150, 0), nominalRest: (162, 0), found: (168, 1))
        }
        XCTAssertEqual(l.observations, 6)
        XCTAssertEqual(l.multiplier, exp(6 * log(1.5) / 8), accuracy: 1e-9, "shrunk toward 1 by the 2-shot prior")
        XCTAssertGreaterThan(l.multiplier, 1.3)
    }

    func testIgnoresTinyRollsAndClampsOutliers() {
        var l = RollLearner()
        l.record(landing: (100, 0), nominalRest: (102, 0), found: (130, 0)) // 2 m predicted roll: ignored
        XCTAssertEqual(l.observations, 0)
        l.record(landing: (100, 0), nominalRest: (110, 0), found: (400, 0)) // ratio 30 → clamped to 3
        XCTAssertEqual(l.multiplier, exp(log(3) / 3), accuracy: 1e-9)
    }

    func testEstimatorScalesRollAndRemembersMultiplier() {
        let cal = TeeCalibration(distanceToTeeMeters: 3, cameraPitchRadians: 0, cameraHeadingDeg: 0,
                                 horizontalFOVRadians: 1.9, teeLocation: GeoCoordinate(latitude: 0, longitude: 0))
        let launch = LaunchVector(ballSpeed: 65, launchAngleDeg: 11, azimuthDeg: 0)
        var e = LandingZoneEstimator()
        let nominal = e.estimate(launch: launch, calibration: cal).landing
        e.rollMultiplier = 2
        let firm = e.estimate(launch: launch, calibration: cal).landing
        XCTAssertEqual(firm.restCarry - firm.carryMeters, 2 * (nominal.restCarry - nominal.carryMeters), accuracy: 1e-6)
        XCTAssertEqual(firm.nominalRest.along, nominal.restCarry, accuracy: 1e-6, "nominal rest recoverable for learning")
    }

    func testShotFrameMatchesProjection() {
        let tee = GeoCoordinate(latitude: 45, longitude: 7)
        let p = GeoMath.project(teeLocation: tee, cameraHeadingDeg: 60, carryMeters: 150, lateralMeters: 12, searchRadiusMeters: 0)
        let l = ShotFrame.local(p.coordinate, tee: tee, headingDeg: 60)
        XCTAssertEqual(l.along, 150, accuracy: 0.05)
        XCTAssertEqual(l.right, 12, accuracy: 0.05)
    }

    func testRollLearningHelpsWhenGroundIsSharedByARound() {
        var base = MonteCarloConfig()
        base.shots = 300
        base.seed = 21
        base.groundPerRound = true
        var learned = base
        learned.rollLearning = true
        XCTAssertLessThan(MonteCarlo.run(learned).p90ErrorYards, MonteCarlo.run(base).p90ErrorYards + 0.5)
    }
}
