import XCTest
@testable import VIGBTCore

final class NavigationTests: XCTestCase {
    private let tee = GeoCoordinate(latitude: 33.5031, longitude: -82.0230)

    // MARK: Geo

    func testDestinationDistanceBearingRoundTrip() {
        for bearing in stride(from: 0.0, to: 360, by: 37) {
            let p = GeoMath.destination(from: tee, distanceMeters: 220, bearingDeg: bearing)
            XCTAssertEqual(GeoMath.distance(from: tee, to: p), 220, accuracy: 0.001)
            XCTAssertEqual(Units.signedAngle(GeoMath.bearing(from: tee, to: p) - bearing), 0, accuracy: 1e-6)
        }
    }

    func testOneDegreeOfLatitude() {
        let a = GeoCoordinate(latitude: 0, longitude: 0)
        let b = GeoCoordinate(latitude: 1, longitude: 0)
        XCTAssertEqual(GeoMath.distance(from: a, to: b), 111_195, accuracy: 5)
    }

    func testENURoundTrip() {
        let p = GeoMath.coordinate(east: 120, north: -45, from: tee)
        let o = GeoMath.enuOffset(of: p, from: tee)
        XCTAssertEqual(o.east, 120, accuracy: 0.01)
        XCTAssertEqual(o.north, -45, accuracy: 0.01)
    }

    // MARK: Engine

    private func target(atYards yards: Double, bearing: Double = 0) -> TargetCoordinate {
        let d = Units.meters(fromYards: yards)
        return TargetCoordinate(coordinate: GeoMath.destination(from: tee, distanceMeters: d, bearingDeg: bearing),
                                bearingFromTeeDeg: bearing, distanceFromTeeMeters: d, searchRadiusMeters: 0.08 * d)
    }

    func testHeadingErrorAndAlignment() {
        var engine = NavigationEngine(target: target(atYards: 150, bearing: 0))
        XCTAssertEqual(engine.update(position: tee, headingDeg: 0).alignment, .onLine)
        let facingEast = engine.update(position: tee, headingDeg: 90)
        XCTAssertEqual(facingEast.headingErrorDeg, -90, accuracy: 0.01)
        XCTAssertEqual(facingEast.alignment, .offLeft)
        XCTAssertLessThan(facingEast.beaconRight, 0)
        XCTAssertLessThan(facingEast.pitchShiftCents, 0)
        let facingWest = engine.update(position: tee, headingDeg: 340)
        XCTAssertEqual(facingWest.alignment, .offRight)
        XCTAssertEqual(engine.update(position: tee, headingDeg: 10).alignment, .onLine)
    }

    func testPulseTempoIncreasesAsDistanceShrinks() {
        var engine = NavigationEngine(target: target(atYards: 200))
        let far = engine.update(position: tee, headingDeg: 0).pulseIntervalSeconds
        let mid = engine.update(position: GeoMath.destination(from: tee, distanceMeters: 120, bearingDeg: 0), headingDeg: 0).pulseIntervalSeconds
        let near = engine.update(position: GeoMath.destination(from: tee, distanceMeters: 175, bearingDeg: 0), headingDeg: 0).pulseIntervalSeconds
        XCTAssertGreaterThan(far, mid)
        XCTAssertGreaterThan(mid, near)
    }

    func testMilestonesAnnouncedOnceInOrder() {
        let total = 160.0
        var engine = NavigationEngine(target: target(atYards: total))
        engine.begin(from: tee)
        var spoken: [NavigationMilestone] = []
        var arrived = false
        for walkedYards in stride(from: 0.0, through: total, by: 2) {
            let pos = GeoMath.destination(from: tee, distanceMeters: Units.meters(fromYards: walkedYards), bearingDeg: 0)
            let g = engine.update(position: pos, headingDeg: 0)
            spoken += g.milestones
            arrived = arrived || g.hasArrived
        }
        XCTAssertEqual(spoken, [.yards100, .yards50, .yards25, .arrived])
        XCTAssertTrue(arrived)
    }

    func testBeginSuppressesMilestonesAlreadyInside() {
        var engine = NavigationEngine(target: target(atYards: 40))
        engine.begin(from: tee)
        let g = engine.update(position: tee, headingDeg: 0)
        XCTAssertTrue(g.milestones.isEmpty, "100/50-yard callouts must not fire on a 40-yard shot")
    }

    // MARK: Kalman

    func testKalmanBlendsDeadReckoningAndGPS() {
        var kf = PositionKalmanFilter(origin: tee, initialVariance: 1)
        kf.predict(distanceWalkedMeters: 10, headingDeg: 0, elapsedSeconds: 8)
        XCTAssertEqual(kf.north, 10, accuracy: 1e-9)
        let gps = GeoMath.coordinate(east: 0, north: 14, from: tee)
        kf.update(gps: gps, horizontalAccuracy: 5)
        XCTAssertGreaterThan(kf.north, 10)
        XCTAssertLessThan(kf.north, 14)
        let before = kf.varianceNorth
        kf.update(gps: gps, horizontalAccuracy: 5)
        XCTAssertLessThan(kf.varianceNorth, before)
    }

    func testKalmanTrustsAccurateGPS() {
        var kf = PositionKalmanFilter(origin: tee, initialVariance: 100)
        kf.update(gps: GeoMath.coordinate(east: 30, north: 0, from: tee), horizontalAccuracy: 0.5)
        XCTAssertEqual(kf.east, 30, accuracy: 0.1)
    }
}
