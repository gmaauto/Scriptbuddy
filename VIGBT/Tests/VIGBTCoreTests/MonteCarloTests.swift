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
