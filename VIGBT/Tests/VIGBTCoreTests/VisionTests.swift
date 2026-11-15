import XCTest
@testable import VIGBTCore

final class VisionTests: XCTestCase {
    // MARK: Colour

    func testRGBToHSV() {
        let orange = HSV(r: 1.0, g: 0.5, b: 0.0)
        XCTAssertEqual(orange.h, 30, accuracy: 1e-9)
        XCTAssertEqual(orange.s, 1, accuracy: 1e-9)
        XCTAssertEqual(orange.v, 1, accuracy: 1e-9)
        let magenta = HSV(r: 1.0, g: 0.0, b: 0.5)
        XCTAssertEqual(magenta.h, 330, accuracy: 1e-9)
    }

    func testPresetMasks() {
        XCTAssertTrue(BallColorProfile.neonOrange.range.contains(HSV(r: 1, g: 0.45, b: 0.05)))
        XCTAssertFalse(BallColorProfile.neonOrange.range.contains(HSV(r: 0.2, g: 0.7, b: 0.2)), "grass")
        XCTAssertTrue(BallColorProfile.neonPink.range.contains(HSV(r: 1, g: 0.2, b: 0.6)))
        XCTAssertFalse(BallColorProfile.neonPink.range.contains(HSV(r: 0.95, g: 0.95, b: 0.95)), "white ball")
    }

    func testTapToSampleHandlesHueWrapAround() throws {
        let patch = [HSV(h: 355, s: 0.8, v: 0.9), HSV(h: 5, s: 0.8, v: 0.9)]
        let profile = try XCTUnwrap(BallColorProfile.sampled(from: patch))
        XCTAssertEqual(profile.preset, .sampled)
        XCTAssertTrue(profile.range.contains(HSV(h: 0, s: 0.8, v: 0.9)))
        XCTAssertTrue(profile.range.contains(HSV(h: 350, s: 0.8, v: 0.9)))
        XCTAssertFalse(profile.range.contains(HSV(h: 180, s: 0.8, v: 0.9)))
        XCTAssertNil(BallColorProfile.sampled(from: []))
    }

    // MARK: Fusion & tracking

    func testCircularityGate() {
        let s = FusionScorer()
        XCTAssertEqual(s.circularity(of: DetectionCandidate(centerX: 0, centerY: 0, width: 10, height: 10, colorMatchFraction: 1)), 1)
        XCTAssertNil(s.circularity(of: DetectionCandidate(centerX: 0, centerY: 0, width: 20, height: 10, colorMatchFraction: 1)))
        XCTAssertNil(s.circularity(of: DetectionCandidate(centerX: 0, centerY: 0, width: 6, height: 10, colorMatchFraction: 1)))
    }

    func testTrackerFollowsBallAndIgnoresDistractors() {
        var frames: [[DetectionCandidate]] = []
        for i in 1...10 {
            let ball = DetectionCandidate(centerX: 900 + Double(i) * 30, centerY: 700 - Double(i) * 12,
                                          width: 12, height: 12, colorMatchFraction: 0.9)
            // A static, round, colour-matching distractor (e.g. tee marker) and an elongated club-head blob.
            let marker = DetectionCandidate(centerX: 400, centerY: 800, width: 14, height: 14, colorMatchFraction: 0.8)
            let club = DetectionCandidate(centerX: 880 + Double(i) * 5, centerY: 720, width: 40, height: 15, colorMatchFraction: 0.1)
            frames.append(i.isMultiple(of: 2) ? [marker, ball, club] : [ball, marker, club])
        }
        let track = BallTracker().track(frames: frames)
        XCTAssertGreaterThanOrEqual(track.count, 8)
        // From the third frame on, the kinematic prior must lock onto the ball.
        for c in track where c.frameOffset >= 3 {
            XCTAssertEqual(c.x, 900 + Double(c.frameOffset) * 30, accuracy: 1e-9)
        }
    }

    func testTrackerStopsAfterBallExitsFrame() {
        var frames: [[DetectionCandidate]] = (1...5).map { i in
            [DetectionCandidate(centerX: Double(i) * 40, centerY: 500, width: 10, height: 10, colorMatchFraction: 1)]
        }
        frames += Array(repeating: [], count: 3)
        frames.append([DetectionCandidate(centerX: 1500, centerY: 100, width: 10, height: 10, colorMatchFraction: 1)])
        XCTAssertEqual(BallTracker().track(frames: frames).count, 5)
    }

    // MARK: Launch-vector extraction

    private func calibration(pitch: Double, roll: Double) -> TeeCalibration {
        TeeCalibration(distanceToTeeMeters: 1, cameraPitchRadians: pitch, cameraRollRadians: roll,
                       cameraHeadingDeg: 0, horizontalFOVRadians: Units.radians(108),
                       teeLocation: GeoCoordinate(latitude: 0, longitude: 0))
    }

    private func roundTrip(_ truth: LaunchVector, tee: Vector3, pitch: Double, roll: Double) throws -> LaunchVector {
        var cal = calibration(pitch: pitch, roll: roll)
        let (centroids, refR) = LaunchVectorExtractor.synthesizeCentroids(launch: truth, calibration: cal, teeWorldPosition: tee)
        // LiDAR would report the tee's optical-axis depth; recover it from the synthetic reference radius.
        cal.distanceToTeeMeters = cal.focalLengthPixels * 0.021335 / refR
        return try LaunchVectorExtractor().extract(centroids: centroids, calibration: cal, referenceRadiusPixels: refR)
    }

    func testDownTheLineRoundTrip() throws {
        let truth = LaunchVector(ballSpeed: 70, launchAngleDeg: 12, azimuthDeg: 3)
        let got = try roundTrip(truth, tee: Vector3(4, -0.3, -1.2), pitch: -atan(1.2 / 4), roll: 0.05)
        XCTAssertEqual(got.ballSpeed, truth.ballSpeed, accuracy: 1e-6)
        XCTAssertEqual(got.launchAngleDeg, truth.launchAngleDeg, accuracy: 1e-6)
        XCTAssertEqual(got.azimuthDeg, truth.azimuthDeg, accuracy: 1e-6)
    }

    func testFaceOnRoundTrip() throws {
        let truth = LaunchVector(ballSpeed: 60, launchAngleDeg: 20, azimuthDeg: 90)
        let got = try roundTrip(truth, tee: Vector3(3, 0, -1), pitch: -atan(1.0 / 3), roll: -0.03)
        XCTAssertEqual(got.ballSpeed, 60, accuracy: 1e-6)
        XCTAssertEqual(got.launchAngleDeg, 20, accuracy: 1e-6)
        XCTAssertEqual(got.azimuthDeg, 90, accuracy: 1e-6)
    }

    func testExtractorRejectsTooFewPoints() {
        let c = [TrackedCentroid(frameOffset: 1, x: 0, y: 0, radiusPixels: 5, score: 1)]
        XCTAssertThrowsError(try LaunchVectorExtractor().extract(centroids: c, calibration: calibration(pitch: 0, roll: 0)))
    }

    func testMetersPerPixelAtTee() {
        var cal = calibration(pitch: 0, roll: 0)
        cal.distanceToTeeMeters = 3
        cal.horizontalFOVRadians = Units.radians(90)
        // f = 960 px → 3 m / 960 px
        XCTAssertEqual(cal.metersPerPixelAtTee, 3.0 / 960, accuracy: 1e-12)
    }
}
