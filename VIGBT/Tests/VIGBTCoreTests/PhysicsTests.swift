import XCTest
@testable import VIGBTCore

final class PhysicsTests: XCTestCase {
    private let solver = BallisticSolver()

    private func carryYards(mph: Double, launch: Double, rpm: Double, azimuth: Double = 0, tilt: Double = 0,
                            wind: Vector3 = .zero) -> TrajectorySolution {
        solver.solve(launch: LaunchVector(ballSpeed: Units.metersPerSecond(fromMph: mph),
                                          launchAngleDeg: launch, azimuthDeg: azimuth),
                     spin: SpinEstimate(rpm: rpm, axisTiltDeg: tilt), wind: wind)
    }

    func testVacuumMatchesAnalyticRange() {
        var model = AerodynamicModel()
        model.airDensity = 0
        let s = BallisticSolver(model: model)
        let v = 50.0
        let sol = s.solve(launch: LaunchVector(ballSpeed: v, launchAngleDeg: 45, azimuthDeg: 0),
                          spin: SpinEstimate(rpm: 3000))
        let analytic = v * v / model.gravity
        XCTAssertEqual(sol.carryMeters, analytic, accuracy: 0.05)
        XCTAssertEqual(sol.apexMeters, v * v / (4 * model.gravity), accuracy: 0.05)
        XCTAssertEqual(sol.flightTimeSeconds, 2 * v * sin(.pi / 4) / model.gravity, accuracy: 0.001)
        XCTAssertEqual(sol.lateralMeters, 0, accuracy: 1e-9)
    }

    /// Calibration targets: PGA Tour TrackMan averages.
    func testTourDriverCarry() {
        let sol = carryYards(mph: 167, launch: 10.9, rpm: 2686)
        XCTAssertEqual(sol.carryYards, 275, accuracy: 15)
        XCTAssertGreaterThan(sol.apexMeters, 20)
        XCTAssertLessThan(sol.apexMeters, 45)
    }

    func testTourSevenIronCarry() {
        XCTAssertEqual(carryYards(mph: 120, launch: 16.3, rpm: 7097).carryYards, 172, accuracy: 10)
    }

    func testTourPitchingWedgeCarry() {
        XCTAssertEqual(carryYards(mph: 102, launch: 24.2, rpm: 9304).carryYards, 136, accuracy: 12)
    }

    func testBackspinIncreasesCarryVersusNoSpinLowLaunch() {
        let withSpin = carryYards(mph: 150, launch: 10, rpm: 2800).carryMeters
        let noSpin = carryYards(mph: 150, launch: 10, rpm: 0).carryMeters
        XCTAssertGreaterThan(withSpin, noSpin)
    }

    func testAzimuthRotatesLandingPointStraightShot() {
        let sol = carryYards(mph: 140, launch: 12, rpm: 3000, azimuth: 10)
        let angle = Units.degrees(atan2(sol.lateralMeters, sol.carryMeters))
        XCTAssertEqual(angle, 10, accuracy: 0.01)
        XCTAssertGreaterThan(sol.lateralMeters, 0, "positive azimuth must land right")
    }

    func testPositiveAxisTiltSlicesRight() {
        let slice = carryYards(mph: 140, launch: 12, rpm: 3000, tilt: 20)
        let hook = carryYards(mph: 140, launch: 12, rpm: 3000, tilt: -20)
        XCTAssertGreaterThan(slice.lateralMeters, 5)
        XCTAssertLessThan(hook.lateralMeters, -5)
    }

    func testHeadwindShortensCarry() {
        let calm = carryYards(mph: 140, launch: 12, rpm: 3000).carryMeters
        let into = carryYards(mph: 140, launch: 12, rpm: 3000, wind: Vector3(-5, 0, 0)).carryMeters
        let down = carryYards(mph: 140, launch: 12, rpm: 3000, wind: Vector3(5, 0, 0)).carryMeters
        XCTAssertLessThan(into, calm)
        XCTAssertGreaterThan(down, calm)
    }

    func testSpinEstimatorHeuristicAndClamp() {
        XCTAssertEqual(SpinEstimator.estimate(launchAngleDeg: 10).rpm, 3_600, accuracy: 1e-9)
        XCTAssertEqual(SpinEstimator.estimate(launchAngleDeg: -5).rpm, 2_000)
        XCTAssertEqual(SpinEstimator.estimate(launchAngleDeg: 60).rpm, 8_500)
    }

    func testAirDensityAtStandardConditions() {
        let rho = AerodynamicModel.airDensity(temperatureC: 15, pressureHPa: 1013.25, relativeHumidity: 0)
        XCTAssertEqual(rho, 1.225, accuracy: 0.001)
    }

    func testLandingZoneEstimatorDispersionAndProjection() {
        let tee = GeoCoordinate(latitude: 51.5, longitude: -0.12)
        let cal = TeeCalibration(distanceToTeeMeters: 3, cameraPitchRadians: 0, cameraHeadingDeg: 90,
                                 horizontalFOVRadians: Units.radians(108), teeLocation: tee)
        let launch = LaunchVector(ballSpeed: Units.metersPerSecond(fromMph: 120), launchAngleDeg: 16, azimuthDeg: 0)
        let result = LandingZoneEstimator().estimate(launch: launch, calibration: cal)
        XCTAssertEqual(result.spin.rpm, 2_200 + 140 * 16, accuracy: 1e-9)
        let e = LandingZoneEstimator()
        XCTAssertEqual(result.landing.searchAlongMeters ?? 0, e.alongFactor * result.trajectory.carryMeters, accuracy: 1e-9)
        XCTAssertEqual(result.landing.searchLateralMeters ?? 0, e.lateralFactor * result.trajectory.carryMeters, accuracy: 1e-9)
        XCTAssertEqual(result.landing.searchRadiusMeters,
                       (e.alongFactor * e.lateralFactor).squareRoot() * result.trajectory.carryMeters, accuracy: 1e-9)
        XCTAssertGreaterThan(result.landing.restCarry, result.landing.carryMeters, "ball rolls on after landing")
        XCTAssertEqual(result.landing.target.bearingFromTeeDeg, 90, accuracy: 1e-6)
        let d = GeoMath.distance(from: tee, to: result.landing.target.coordinate)
        XCTAssertEqual(d, result.landing.restCarry, accuracy: 0.01, "navigation target is the rest point")
    }

    func testClubSelectionFixesIronCarry() {
        let launch = LaunchVector(ballSpeed: Units.metersPerSecond(fromMph: 120), launchAngleDeg: 16.3, azimuthDeg: 0)
        let auto = solver.solve(launch: launch, spin: SpinEstimator.estimate(club: .auto, launchAngleDeg: 16.3))
        let midIron = solver.solve(launch: launch, spin: SpinEstimator.estimate(club: .midIron, launchAngleDeg: 16.3))
        XCTAssertEqual(midIron.carryYards, 172, accuracy: 6, "tour 7-iron average")
        XCTAssertGreaterThan(auto.carryYards, midIron.carryYards + 8, "formula spin flies irons long")
        XCTAssertEqual(SpinEstimator.estimate(club: .wedge, launchAngleDeg: 25).rpm, SpinEstimator.maximumRPM)
        XCTAssertEqual(SpinEstimator.estimate(club: .auto, launchAngleDeg: 10).rpm, 3_600, accuracy: 1e-9)
    }
}
