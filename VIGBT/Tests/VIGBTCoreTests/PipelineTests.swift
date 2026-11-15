import XCTest
@testable import VIGBTCore

final class PipelineTests: XCTestCase {
    // MARK: Camera pose

    func testPitchAndRollRoundTripThroughLevel() {
        for (pitch, roll) in [(0.0, 0.0), (-0.3, 0.1), (0.2, -0.25), (0.0, Double.pi)] {
            // Gravity in camera frame for this pose (see LaunchVectorExtractor.level inverse).
            let g = Vector3(sin(roll) * cos(pitch), cos(roll) * cos(pitch), -sin(pitch))
            let pose = CameraPose.pitchAndRoll(gravityInCamera: g * 9.81)
            XCTAssertEqual(pose.pitch, pitch, accuracy: 1e-9)
            XCTAssertEqual(Units.signedAngle(Units.degrees(pose.roll - roll)), 0, accuracy: 1e-7)
            let levelled = LaunchVectorExtractor.level(g, pitch: pose.pitch, roll: pose.roll)
            XCTAssertEqual(levelled.x, 0, accuracy: 1e-9)
            XCTAssertEqual(levelled.y, 1, accuracy: 1e-9)
            XCTAssertEqual(levelled.z, 0, accuracy: 1e-9)
        }
    }

    func testHeadingFromEastNorth() {
        XCTAssertEqual(CameraPose.heading(east: 0, north: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(CameraPose.heading(east: 1, north: 0), 90, accuracy: 1e-9)
        XCTAssertEqual(CameraPose.heading(east: -1, north: -1), 225, accuracy: 1e-9)
    }

    // MARK: Masks & blobs

    /// Builds a BGRA image with a background colour and filled discs.
    private func image(width: Int, height: Int, background: (UInt8, UInt8, UInt8),
                       discs: [(x: Double, y: Double, r: Double, rgb: (UInt8, UInt8, UInt8))]) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var c = background
                for d in discs where (Double(x) + 0.5 - d.x) * (Double(x) + 0.5 - d.x) + (Double(y) + 0.5 - d.y) * (Double(y) + 0.5 - d.y) <= d.r * d.r {
                    c = d.rgb
                }
                let o = (y * width + x) * 4
                px[o] = c.2; px[o + 1] = c.1; px[o + 2] = c.0
            }
        }
        return px
    }

    func testColorMaskAndBlobOnGrass() {
        let grass: (UInt8, UInt8, UInt8) = (60, 140, 50)
        let orange: (UInt8, UInt8, UInt8) = (255, 120, 20)
        let px = image(width: 80, height: 60, background: grass, discs: [(x: 30, y: 20, r: 5, rgb: orange)])
        let masks = px.withUnsafeBytes {
            FrameMasks.build(bgra: $0, width: 80, height: 60, bytesPerRow: 320, range: BallColorProfile.neonOrange.range)
        }
        let blobs = BlobDetector().detect(mask: masks.color, width: masks.width, height: masks.height, color: masks.color)
        XCTAssertEqual(blobs.count, 1)
        let b = blobs[0]
        XCTAssertEqual(b.centerX, 30, accuracy: 0.5)
        XCTAssertEqual(b.centerY, 20, accuracy: 0.5)
        XCTAssertEqual(b.radiusPixels, 5, accuracy: 1)
        XCTAssertEqual(b.colorMatchFraction, 1)
        XCTAssertNotNil(FusionScorer().circularity(of: b))
    }

    func testMotionMaskFindsMovedBallAtStep2() {
        let bg: (UInt8, UInt8, UInt8) = (100, 100, 100)
        let white: (UInt8, UInt8, UInt8) = (250, 250, 250)
        let a = image(width: 100, height: 60, background: bg, discs: [(x: 20, y: 30, r: 4, rgb: white)])
        let b = image(width: 100, height: 60, background: bg, discs: [(x: 70, y: 24, r: 4, rgb: white)])
        let ma = a.withUnsafeBytes { FrameMasks.build(bgra: $0, width: 100, height: 60, bytesPerRow: 400, step: 2, range: nil) }
        let mb = b.withUnsafeBytes { FrameMasks.build(bgra: $0, width: 100, height: 60, bytesPerRow: 400, step: 2, range: nil) }
        let motion = mb.motion(since: ma)
        let blobs = BlobDetector(minArea: 1).detect(mask: motion, width: mb.width, height: mb.height, step: 2)
        // One blob where the ball left, one where it arrived — both in source pixel coordinates.
        XCTAssertEqual(blobs.count, 2)
        XCTAssertTrue(blobs.contains { abs($0.centerX - 70) < 1.5 && abs($0.centerY - 24) < 1.5 })
        XCTAssertTrue(blobs.contains { abs($0.centerX - 20) < 1.5 && abs($0.centerY - 30) < 1.5 })
    }

    func testBlobAreaLimits() {
        var mask = [UInt8](repeating: 0, count: 100)
        mask[0] = 1                                   // 1-pixel speck
        for i in 50..<100 { mask[i] = 1 }             // 50-pixel slab
        let blobs = BlobDetector(minArea: 2, maxArea: 40).detect(mask: mask, width: 10, height: 10)
        XCTAssertTrue(blobs.isEmpty)
    }

    // MARK: End-to-end analyzer

    func testAnalyzerEndToEndWithDistractors() throws {
        var cal = TeeCalibration(distanceToTeeMeters: 1, cameraPitchRadians: -atan(1.2 / 3.5), cameraRollRadians: 0.02,
                                 cameraHeadingDeg: 45, horizontalFOVRadians: Units.radians(108),
                                 teeLocation: GeoCoordinate(latitude: 40, longitude: -75))
        let truth = LaunchVector(ballSpeed: 62, launchAngleDeg: 13, azimuthDeg: 2)
        let synth = LaunchVectorExtractor.synthesizeCentroids(launch: truth, calibration: cal,
                                                              teeWorldPosition: Vector3(3.5, 0.2, -1.2),
                                                              frames: 1...14)
        cal.distanceToTeeMeters = cal.focalLengthPixels * 0.021335 / synth.referenceRadius

        let frames: [[DetectionCandidate]] = synth.centroids.map { c in
            let ball = DetectionCandidate(centerX: c.x, centerY: c.y, width: 2 * c.radiusPixels,
                                          height: 2 * c.radiusPixels, colorMatchFraction: 0.9)
            let clubhead = DetectionCandidate(centerX: 900, centerY: 800, width: 60, height: 30, colorMatchFraction: 0)
            let speck = DetectionCandidate(centerX: 100, centerY: 100, width: 1, height: 1, colorMatchFraction: 0)
            return [clubhead, ball, speck]
        }
        let analysis = ShotAnalyzer().analyze(frames: frames, calibration: cal,
                                              referenceRadiusPixels: synth.referenceRadius, includeBallistics: true)
        let launch = try XCTUnwrap(analysis.launch, analysis.failureReason ?? "")
        XCTAssertEqual(launch.ballSpeed, 62, accuracy: 1e-6)
        XCTAssertEqual(launch.launchAngleDeg, 13, accuracy: 1e-6)
        XCTAssertEqual(launch.azimuthDeg, 2, accuracy: 1e-6)
        let landing = try XCTUnwrap(analysis.landing)
        XCTAssertGreaterThan(landing.carryMeters, 100)
        XCTAssertEqual(landing.target.bearingFromTeeDeg, 47, accuracy: 0.5)
    }

    func testAnalyzerFreeTierSkipsBallisticsAndReportsFailure() {
        let cal = TeeCalibration(distanceToTeeMeters: 3, cameraPitchRadians: 0, cameraHeadingDeg: 0,
                                 horizontalFOVRadians: Units.radians(108),
                                 teeLocation: GeoCoordinate(latitude: 0, longitude: 0))
        let empty = ShotAnalyzer().analyze(frames: Array(repeating: [], count: 12), calibration: cal,
                                           referenceRadiusPixels: nil, includeBallistics: false)
        XCTAssertFalse(empty.succeeded)
        XCTAssertNotNil(empty.failureReason)
    }

    func testReadouts() {
        let l = LaunchVector(ballSpeed: Units.metersPerSecond(fromMph: 150), launchAngleDeg: 12, azimuthDeg: -4)
        XCTAssertEqual(Readout.launch(l), "Ball speed 150 miles per hour. Launch angle 12 degrees. Direction 4 degrees left.")
    }
}
