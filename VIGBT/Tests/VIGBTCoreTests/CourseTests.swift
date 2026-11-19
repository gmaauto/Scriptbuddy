import XCTest
@testable import VIGBTCore

final class CourseTests: XCTestCase {
    private let tee = GeoCoordinate(latitude: 40, longitude: -75)

    private func dest(_ c: GeoCoordinate, _ d: Double, _ b: Double) -> GeoCoordinate {
        GeoMath.destination(from: c, distanceMeters: d, bearingDeg: b)
    }

    private func geom(_ pts: [GeoCoordinate]) -> [[String: Double]] {
        pts.map { ["lat": $0.latitude, "lon": $0.longitude] }
    }

    /// Two-hole course in Overpass `out geom` JSON.
    /// Hole 1: par 4, 350 m, bends 20° right at 200 m; water across the line at 115–125 m;
    /// bunker right at ~182–200 m; white and red tees; pin 5 m past the green centre.
    /// Hole 2: par 3, 150 m due east, green mapped as a node.
    private func overpassFixture() throws -> Data {
        let p1 = dest(tee, 200, 0)
        let p2 = dest(p1, 150, 20)
        let green = [dest(p2, 15, 200), dest(p2, 10, 110), dest(p2, 15, 20), dest(p2, 10, 290), dest(p2, 15, 200)]
        let bc = dest(dest(tee, 190, 0), 25, 90)
        let bunker = [dest(bc, 8, 0), dest(bc, 8, 90), dest(bc, 8, 180), dest(bc, 8, 270)]
        let a = dest(tee, 115, 0), b = dest(tee, 125, 0)
        let water = [dest(a, 20, 270), dest(a, 20, 90), dest(b, 20, 90), dest(b, 20, 270)]
        let t2 = dest(p2, 40, 90)
        let e2 = dest(t2, 150, 90)
        let red = dest(tee, 30, 0)
        let pin = dest(p2, 5, 20)

        let elements: [[String: Any]] = [
            ["type": "way", "id": 100, "tags": ["leisure": "golf_course", "name": "Test Links"], "geometry": geom([tee, e2])],
            ["type": "way", "id": 1, "tags": ["golf": "hole", "ref": "1", "par": "4", "handicap": "7"], "geometry": geom([tee, p1, p2])],
            ["type": "node", "id": 2, "lat": tee.latitude, "lon": tee.longitude, "tags": ["golf": "tee", "tee": "white"]],
            ["type": "node", "id": 3, "lat": red.latitude, "lon": red.longitude, "tags": ["golf": "tee", "tee": "red"]],
            ["type": "way", "id": 4, "tags": ["golf": "green"], "geometry": geom(green)],
            ["type": "node", "id": 5, "lat": pin.latitude, "lon": pin.longitude, "tags": ["golf": "pin"]],
            ["type": "way", "id": 6, "tags": ["golf": "bunker"], "geometry": geom(bunker)],
            ["type": "way", "id": 7, "tags": ["golf": "water_hazard"], "geometry": geom(water)],
            ["type": "way", "id": 8, "tags": ["golf": "hole", "ref": "2", "par": "3"], "geometry": geom([t2, e2])],
            ["type": "node", "id": 9, "lat": e2.latitude, "lon": e2.longitude, "tags": ["golf": "green"]],
        ]
        return try JSONSerialization.data(withJSONObject: ["elements": elements])
    }

    private func course() throws -> GolfCourse {
        let features = try OverpassParser.parseFeatures(try overpassFixture())
        return try CourseAssembler.assemble(id: "osm:way/100", name: "Test Links", features: features,
                                            source: .openStreetMap, attribution: GolfCourse.osmAttribution)
    }

    // MARK: Parsing & assembly

    func testAssemblesHolesTeesGreensPins() throws {
        let c = try course()
        XCTAssertEqual(c.holeNumbers, [1, 2])
        let h1 = try XCTUnwrap(c.hole(1))
        XCTAssertEqual(h1.par, 4)
        XCTAssertEqual(h1.strokeIndex, 7)
        XCTAssertEqual(h1.tees.map(\.name), ["White", "Red"])
        XCTAssertEqual(c.teeSetNames, ["White", "Red", "Tee"], "hole 2 has no mapped tee, so one is synthesised")
        XCTAssertNotNil(h1.pin)
        XCTAssertNil(c.hole(2)?.pin)
        XCTAssertEqual(h1.hazards.map(\.kind).sorted { $0.rawValue < $1.rawValue }, [.bunker, .water])

        let g = try XCTUnwrap(HoleGeometry(hole: h1))
        XCTAssertEqual(g.length, 350, accuracy: 0.5)
        let green = try XCTUnwrap(h1.green)
        XCTAssertEqual(g.project(green.front).along, 335, accuracy: 1)
        XCTAssertEqual(g.project(green.back).along, 365, accuracy: 1)
        XCTAssertEqual(g.remainingLength(from: try XCTUnwrap(h1.tee(named: "red")).coordinate), 320, accuracy: 0.5)
    }

    func testHazardSpansAndDogleg() throws {
        let h1 = try XCTUnwrap(try course().hole(1))
        let g = try XCTUnwrap(HoleGeometry(hole: h1))
        let spans = g.hazardSpans()
        let water = try XCTUnwrap(spans.first { $0.kind == .water })
        XCTAssertEqual(water.side, .crossing)
        XCTAssertEqual(water.start, 115, accuracy: 0.5)
        XCTAssertEqual(water.end, 125, accuracy: 0.5)
        let bunker = try XCTUnwrap(spans.first { $0.kind == .bunker })
        XCTAssertEqual(bunker.side, .right)
        XCTAssertEqual(bunker.start, 182, accuracy: 1)

        let d = try XCTUnwrap(g.doglegs().first)
        XCTAssertEqual(d.side, .right)
        XCTAssertEqual(d.angleDeg, 20, accuracy: 0.5)
        XCTAssertEqual(d.along, 200, accuracy: 0.5)

        // Relative to a golfer 100 m down the line, the water starts 15 m ahead.
        let rel = CourseLocator.hazards(hole: h1, from: dest(tee, 100, 0))
        XCTAssertEqual(try XCTUnwrap(rel.first { $0.kind == .water }).start, 15, accuracy: 0.5)
    }

    func testLayoutRotationPutsGreenUp() throws {
        let h2 = try XCTUnwrap(try course().hole(2))
        let g = try XCTUnwrap(HoleGeometry(hole: h2))
        XCTAssertEqual(g.bearingDeg, 90, accuracy: 0.5)
        let end = g.layoutPoint(try XCTUnwrap(h2.green).center)
        XCTAssertEqual(end.x, 0, accuracy: 0.5)
        XCTAssertEqual(end.y, 150, accuracy: 0.5)
        let rightOfLine = g.layoutPoint(dest(h2.centerline[0], 10, 180)) // south = right when facing east
        XCTAssertEqual(rightOfLine.x, 10, accuracy: 0.1)
    }

    func testSummariesSortedByDistance() throws {
        let json = """
        {"elements":[
          {"type":"way","id":5,"center":{"lat":40.02,"lon":-75},"tags":{"name":"Far Club"}},
          {"type":"relation","id":6,"center":{"lat":40.001,"lon":-75},"tags":{"name":"Near Club"}}
        ]}
        """
        let s = try OverpassParser.parseSummaries(Data(json.utf8), from: tee)
        XCTAssertEqual(s.map(\.name), ["Near Club", "Far Club"])
        XCTAssertEqual(s.first?.id, "relation/6")
        XCTAssertTrue(OverpassParser.courseQuery(id: "relation/6").contains("relation(6);map_to_area->.c;"))
        XCTAssertTrue(OverpassParser.nearbyQuery(center: tee, radiusMeters: 5000).contains("around:5000,40.0,-75.0"))
    }

    func testGeoJSONImport() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"leisure":"golf_course","name":"Imported GC"},
           "geometry":{"type":"Point","coordinates":[-75.0,40.0]}},
          {"type":"Feature","properties":{"golf":"hole","ref":3,"par":"5"},
           "geometry":{"type":"LineString","coordinates":[[-75.0,40.0],[-75.0,40.004]]}},
          {"type":"Feature","properties":{"golf":"green"},
           "geometry":{"type":"Polygon","coordinates":[[[-75.0001,40.004],[-74.9999,40.004],[-74.9999,40.0041],[-75.0001,40.004]]]}}
        ]}
        """
        let parsed = try GeoJSONParser.parse(Data(json.utf8))
        XCTAssertEqual(parsed.name, "Imported GC")
        let c = try CourseAssembler.assemble(id: "import:x", name: parsed.name ?? "", features: parsed.features, source: .imported)
        let h = try XCTUnwrap(c.hole(3))
        XCTAssertEqual(h.par, 5)
        XCTAssertNotNil(h.green)
        XCTAssertThrowsError(try CourseAssembler.assemble(id: "x", name: "x", features: [], source: .imported))
    }

    // MARK: Description

    func testHoleDescriptionFromTee() throws {
        let h1 = try XCTUnwrap(try course().hole(1))
        let d = HoleDescriber.describe(hole: h1, teeName: "White", golfer: nil)
        XCTAssertEqual(d.summary, "Hole 1, par 4, 383 yards, stroke index 7.")
        let texts = d.features.map(\.text)
        XCTAssertEqual(texts.first, "Water across the line from 126 to 137 yards.")
        XCTAssertTrue(texts.contains("Fairway bends right at 219 yards."))
        XCTAssertTrue(texts.contains { $0.hasPrefix("Bunker on the right from 199 to ") })
        XCTAssertTrue(texts.contains { $0.hasPrefix("Green: front 366") && $0.contains("deep") })
        XCTAssertEqual(d.features.last?.kind, .pin)
        // From the red tee the hole is 30 m shorter.
        XCTAssertEqual(HoleDescriber.describe(hole: h1, teeName: "Red", golfer: nil).summary,
                       "Hole 1, par 4, 350 yards, stroke index 7.")
    }

    func testUnmappedHoleDescription() {
        let d = HoleDescriber.describe(hole: Hole(number: 5, par: 3), teeName: nil, golfer: nil)
        XCTAssertEqual(d.summary, "Hole 5, par 3. This hole has not been mapped yet.")
    }

    // MARK: Club advice

    private let bag = ClubBag.standard

    func testRecommendsSmallestClubThatReaches() throws {
        let r = try XCTUnwrap(ClubAdvisor.recommend(distanceToPinMeters: Units.meters(fromYards: 140), bag: bag))
        XCTAssertEqual(r.recommended, .iron7)
        XCTAssertEqual(r.reason, .reaches)
        XCTAssertEqual(r.alternatives, [.iron6, .iron8])
        XCTAssertEqual(r.readout, "140 yards to the pin. Recommended: 7-iron. Your 7-iron carries 140.")
    }

    func testUphillPlaysLonger() throws {
        let r = try XCTUnwrap(ClubAdvisor.recommend(distanceToPinMeters: Units.meters(fromYards: 140), bag: bag,
                                                    elevationChangeMeters: 10))
        XCTAssertEqual(Units.yards(fromMeters: r.playsLikeMeters), 150, accuracy: 0.01)
        XCTAssertEqual(r.recommended, .iron6)
        XCTAssertTrue(r.readout.contains("Plays 150."))
    }

    func testWindAdjustment() {
        XCTAssertEqual(ClubAdvisor.playsLike(distanceMeters: 100, headwindMph: 10), 110, accuracy: 1e-9)
        XCTAssertEqual(ClubAdvisor.playsLike(distanceMeters: 100, headwindMph: -10), 95, accuracy: 1e-9)
    }

    func testLayUpShortOfCrossingHazard() throws {
        let water = HazardSpan(kind: .water, start: 190, end: 215, side: .crossing)
        let r = try XCTUnwrap(ClubAdvisor.recommend(distanceToPinMeters: Units.meters(fromYards: 300), bag: bag,
                                                    hazards: [water]))
        XCTAssertEqual(r.recommended, .wood5)
        XCTAssertEqual(r.reason, .layUp)
        XCTAssertTrue(r.readout.contains("Lay up with 5-wood"))
        XCTAssertTrue(r.readout.contains("short of the water at 208 yards"))
    }

    func testOutOfRangeWithoutHazardsHitsLongest() throws {
        let r = try XCTUnwrap(ClubAdvisor.recommend(distanceToPinMeters: Units.meters(fromYards: 300), bag: bag))
        XCTAssertEqual(r.recommended, .driver)
        XCTAssertEqual(r.reason, .longest)
    }

    func testShortShotIsPartialWithShortestClub() throws {
        let r = try XCTUnwrap(ClubAdvisor.recommend(distanceToPinMeters: Units.meters(fromYards: 40), bag: bag))
        XCTAssertEqual(r.recommended, .lobWedge)
        XCTAssertEqual(r.reason, .partialShot)
    }

    func testBagLearnsFromRealShotsOnly() throws {
        let cal = TeeCalibration(distanceToTeeMeters: 3, cameraPitchRadians: 0, cameraHeadingDeg: 0,
                                 horizontalFOVRadians: 1.9, teeLocation: tee)
        func shot(_ carry: Double, simulated: Bool = false, ago: Double) -> ShotRecord {
            ShotRecord(capturedAt: Date(timeIntervalSinceNow: -ago), ballProfile: .neonOrange, calibration: cal,
                       trajectory: TrajectorySolution(samples: [], carryMeters: carry, lateralMeters: 0, apexMeters: 0,
                                                      flightTimeSeconds: 0, landingSpeed: 0, landingAngleDeg: 0),
                       isSimulated: simulated, bagClub: .iron7)
        }
        var b = ClubBag.standard
        b.learn(from: [shot(150, ago: 1), shot(152, ago: 2)])
        XCTAssertEqual(try XCTUnwrap(b[.iron7]).effectiveCarryMeters, Units.meters(fromYards: 140), accuracy: 1e-9,
                       "two samples are not enough to override the default")
        b.learn(from: [shot(150, ago: 1), shot(152, ago: 2), shot(148, ago: 3), shot(151, ago: 4), shot(300, simulated: true, ago: 0)])
        XCTAssertEqual(try XCTUnwrap(b[.iron7]).effectiveCarryMeters, 150.5, accuracy: 1e-9)
        XCTAssertTrue(try XCTUnwrap(b[.iron7]).isLearned)
        b.update(.iron7) { $0.userCarryMeters = 130 }
        XCTAssertEqual(try XCTUnwrap(b[.iron7]).effectiveCarryMeters, 130)
    }

    // MARK: Round & marking

    func testRoundWrapsForShotgunStart() {
        let holes = Array(1...18)
        var r = RoundState(courseID: "c", teeSetName: "White", startingHole: 18)
        XCTAssertEqual(r.next(in: holes), 1)
        XCTAssertEqual(r.previous(in: holes), 17)
        r.advance(to: r.next(in: holes))
        XCTAssertEqual(r.currentHole, 1)
        XCTAssertEqual(r.holesCompleted, [18])
        let id = UUID()
        r.record(shot: id)
        XCTAssertEqual(r.shotsByHole[1], [id])
    }

    func testMarkingACourseOnSite() throws {
        var c = GolfCourse.marked(name: "Home", location: tee, holeCount: 9)
        XCTAssertEqual(c.holes.count, 9)
        c.markTee(hole: 1, at: tee)
        c.markGreen(hole: 1, at: dest(tee, 300, 45))
        let g = try XCTUnwrap(HoleGeometry(hole: try XCTUnwrap(c.hole(1))))
        XCTAssertEqual(g.length, 300, accuracy: 0.5)
        let pin = dest(tee, 305, 45)
        c.setPin(hole: 1, at: pin)
        XCTAssertEqual(c.hole(1)?.target, pin)
        XCTAssertEqual(CourseLocator.holeOnTee(course: c, position: dest(tee, 5, 0)), 1)
        XCTAssertNil(CourseLocator.holeOnTee(course: c, position: dest(tee, 60, 0)))
    }

    // MARK: Learned search zone (ball finder)

    private func foundShot(carry: Double, lateral: Double, foundAlong: Double, foundRight: Double,
                           heading: Double = 30, simulated: Bool = false, club: Club = .midIron) -> ShotRecord {
        let cal = TeeCalibration(distanceToTeeMeters: 3, cameraPitchRadians: 0, cameraHeadingDeg: heading,
                                 horizontalFOVRadians: 1.9, teeLocation: tee)
        let target = GeoMath.project(teeLocation: tee, cameraHeadingDeg: heading, carryMeters: carry,
                                     lateralMeters: lateral, searchRadiusMeters: 0.08 * carry)
        let landing = LandingEstimate(carryMeters: carry, lateralMeters: lateral, searchRadiusMeters: 0.08 * carry, target: target)
        let found = GeoMath.project(teeLocation: tee, cameraHeadingDeg: heading, carryMeters: foundAlong,
                                    lateralMeters: foundRight, searchRadiusMeters: 0).coordinate
        return ShotRecord(ballProfile: .neonOrange, calibration: cal, landing: landing, club: club,
                          isSimulated: simulated, foundLocation: found)
    }

    func testSearchZoneSampleGeometry() throws {
        let s = SearchZoneModel.samples(from: [foundShot(carry: 150, lateral: 4, foundAlong: 140, foundRight: 9)])
        let e = try XCTUnwrap(s.first)
        XCTAssertEqual(e.alongError, -10, accuracy: 0.05)
        XCTAssertEqual(e.lateralError, 5, accuracy: 0.05)
    }

    func testSearchZoneLearnsBiasAndRadius() {
        // Balls consistently land ~10% short and 3% right of the prediction, with a little scatter.
        let shots = [(-0.08, 0.02), (-0.10, 0.03), (-0.12, 0.04), (-0.10, 0.03), (-0.09, 0.025), (-0.11, 0.035)].map {
            foundShot(carry: 150, lateral: 0, foundAlong: 150 * (1 + $0.0), foundRight: 150 * $0.1)
        }
        let cal = SearchZoneModel.calibration(for: .midIron, shots: shots)
        XCTAssertEqual(cal.sampleCount, 6)
        XCTAssertEqual(cal.carryBias, -0.10, accuracy: 0.005)
        XCTAssertEqual(cal.lateralBias, 0.03, accuracy: 0.003)
        XCTAssertEqual(cal.radiusFactor, SearchZoneModel.radiusFactorBounds.lowerBound, accuracy: 1e-9,
                       "tight pattern → the minimum radius factor")
        let c = cal.corrected(carry: 150, lateral: 0)
        XCTAssertEqual(c.carry, 135, accuracy: 1)
        XCTAssertEqual(c.lateral, 4.5, accuracy: 0.5)
    }

    func testSearchZoneNeedsEnoughRealSamples() {
        let few = (0..<4).map { _ in foundShot(carry: 150, lateral: 0, foundAlong: 120, foundRight: 0) }
        XCTAssertEqual(SearchZoneModel.calibration(for: .midIron, shots: few), .uncalibrated)
        let simulated = (0..<8).map { _ in foundShot(carry: 150, lateral: 0, foundAlong: 120, foundRight: 0, simulated: true) }
        XCTAssertEqual(SearchZoneModel.calibration(for: .midIron, shots: simulated), .uncalibrated)
    }

    func testEstimatorAppliesLearnedZone() {
        let cal = TeeCalibration(distanceToTeeMeters: 3, cameraPitchRadians: 0, cameraHeadingDeg: 0,
                                 horizontalFOVRadians: 1.9, teeLocation: tee)
        let launch = LaunchVector(ballSpeed: 55, launchAngleDeg: 16, azimuthDeg: 0)
        let plain = LandingZoneEstimator().estimate(launch: launch, calibration: cal)
        let zone = SearchZoneCalibration(carryBias: -0.1, lateralBias: 0.02, radiusFactor: 0.05, sampleCount: 6)
        let learned = LandingZoneEstimator().estimate(launch: launch, calibration: cal, zone: zone)
        XCTAssertEqual(learned.landing.carryMeters, plain.landing.carryMeters, accuracy: 1e-9, "raw carry unchanged")
        XCTAssertEqual(learned.landing.restCarry, plain.landing.restCarry * 0.9, accuracy: 1e-6)
        XCTAssertEqual(learned.landing.restLateral, plain.landing.restLateral + 0.02 * plain.landing.restCarry, accuracy: 1e-6)
        XCTAssertEqual(learned.landing.searchRadiusMeters, 0.05 * learned.landing.restCarry, accuracy: 1e-6)
    }
}

/// Course-map surfaces for roll (SPEC §12.8).
final class SurfaceMapTests: XCTestCase {
    private let tee = GeoCoordinate(latitude: 40, longitude: -75)
    private func d(_ m: Double, _ b: Double) -> GeoCoordinate { GeoMath.destination(from: tee, distanceMeters: m, bearingDeg: b) }
    /// Rectangle along bearing 0 from `from` to `to` metres, `hw` either side.
    private func strip(_ from: Double, _ to: Double, _ hw: Double, offset: Double = 0) -> [GeoCoordinate] {
        [GeoMath.destination(from: d(from, 0), distanceMeters: hw - offset, bearingDeg: 270),
         GeoMath.destination(from: d(to, 0), distanceMeters: hw - offset, bearingDeg: 270),
         GeoMath.destination(from: d(to, 0), distanceMeters: hw + offset, bearingDeg: 90),
         GeoMath.destination(from: d(from, 0), distanceMeters: hw + offset, bearingDeg: 90)]
    }

    func testClassifiesSurfaces() {
        let map = SurfaceMap(fairways: [strip(50, 300, 18)], greens: [strip(300, 330, 12)],
                             bunkers: [[d(200, 2), d(210, 2), d(210, 5), d(200, 5)]],
                             water: [strip(120, 130, 40)])
        XCTAssertEqual(map.surface(at: d(180, 0)), .fairway)
        XCTAssertEqual(map.surface(at: GeoMath.destination(from: d(180, 0), distanceMeters: 25, bearingDeg: 90)), .rough)
        XCTAssertEqual(map.surface(at: d(315, 0)), .green)
        XCTAssertEqual(map.surface(at: d(125, 0)), .water, "water wins over fairway")
        XCTAssertEqual(map.surface(at: d(205, 3.5)), .bunker)
        XCTAssertEqual(SurfaceMap().surface(at: d(100, 0)), .fairway, "unmapped hole behaves as before")
    }

    func testWalkReadoutNamesTheSearchZone() {
        XCTAssertEqual(Readout.distanceToSearchZone(yards: 94.4), "94 yards to the search zone")
        XCTAssertEqual(Readout.distanceToSearchZone(yards: -3), "0 yards to the search zone")
    }

    func testRoughRollsLessAndReadoutSaysSo() {
        let cal = TeeCalibration(distanceToTeeMeters: 3, cameraPitchRadians: 0, cameraHeadingDeg: 0,
                                 horizontalFOVRadians: 1.9, teeLocation: tee)
        let launch = LaunchVector(ballSpeed: 65, launchAngleDeg: 11, azimuthDeg: 0)
        let e = LandingZoneEstimator()
        let onFairway = e.estimate(launch: launch, calibration: cal, surfaceMap: SurfaceMap(fairways: [strip(0, 400, 20)])).landing
        let inRough = e.estimate(launch: launch, calibration: cal, surfaceMap: SurfaceMap(fairways: [strip(0, 400, 20, offset: 60)])).landing
        XCTAssertEqual(onFairway.landingSurface, .fairway)
        XCTAssertEqual(inRough.landingSurface, .rough)
        XCTAssertLessThan(inRough.rollMeters, onFairway.rollMeters)
        XCTAssertTrue(Readout.landing(inRough).contains("It should land in the rough."))
        XCTAssertFalse(Readout.landing(onFairway).contains("should land"))
        let wet = e.estimate(launch: launch, calibration: cal, surfaceMap: SurfaceMap(water: [strip(0, 400, 20)])).landing
        XCTAssertEqual(wet.landingSurface, .water)
        XCTAssertLessThan(wet.rollMeters, 0.5)
        // Water is announced first, before the numbers, and not repeated in the landing sentence.
        let summary = Readout.shotSummary(launch: launch, landing: wet)
        XCTAssertTrue(summary.hasPrefix(Readout.waterWarning))
        XCTAssertEqual(summary.components(separatedBy: "in the water").count, 2, "said once")
        XCTAssertFalse(Readout.shotSummary(launch: launch, landing: inRough).contains("water"))
        XCTAssertTrue(Readout.shotSummary(launch: launch, landing: inRough).hasPrefix(Readout.launch(launch)))
    }

    func testWaterShotOffersDropNotWalk() throws {
        let cal = TeeCalibration(distanceToTeeMeters: 3, cameraPitchRadians: 0, cameraHeadingDeg: 0,
                                 horizontalFOVRadians: 1.9, teeLocation: tee)
        let launch = LaunchVector(ballSpeed: 65, launchAngleDeg: 11, azimuthDeg: 0)
        let wet = LandingZoneEstimator().estimate(launch: launch, calibration: cal,
                                                  surfaceMap: SurfaceMap(water: [strip(0, 400, 20)])).landing
        var shot = ShotRecord(ballProfile: .neonOrange, calibration: cal, launch: launch, landing: wet)
        XCTAssertTrue(shot.landsInWater)
        shot.droppedFromWater = true
        // The new optional field round-trips, and files without it still decode.
        let data = try DataFormat.encode([shot], format: DataFormat.shots)
        let back = try DataFormat.decode([ShotRecord].self, from: data, supported: DataFormat.shots)
        XCTAssertEqual(back.first?.droppedFromWater, true)
    }
}
