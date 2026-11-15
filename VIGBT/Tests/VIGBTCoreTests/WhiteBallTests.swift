import XCTest
@testable import VIGBTCore

/// Scenes mirror the Python prototype used to tune `WhiteBallDetector` (SPEC §4 Phase 4.5).
final class WhiteBallTests: XCTestCase {
    private let w = 200, h = 150
    private typealias C = (UInt8, UInt8, UInt8)
    private let grass: C = (60, 140, 50)
    private let white: C = (245, 245, 245)

    /// Deterministic ±10 texture so backgrounds are not perfectly flat.
    private func noise(_ x: Int, _ y: Int) -> Int { ((x &* 73856093) ^ (y &* 19349663)) % 21 - 10 }

    private func scene(_ bg: C, discs: [(Double, Double, Double, C)] = [], rects: [(Int, Int, Int, Int, C)] = [],
                       skyRows: Int = 0) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }
        for y in 0..<h {
            for x in 0..<w {
                let n = noise(x, y)
                let base: C = y >= skyRows ? bg : (235, 240, 245)
                var c: C = (clamp(Int(base.0) + n), clamp(Int(base.1) + n), clamp(Int(base.2) + n))
                for d in discs where (Double(x) + 0.5 - d.0) * (Double(x) + 0.5 - d.0) + (Double(y) + 0.5 - d.1) * (Double(y) + 0.5 - d.1) <= d.2 * d.2 {
                    c = d.3
                }
                for r in rects where x >= r.0 && y >= r.1 && x < r.2 && y < r.3 { c = r.4 }
                let o = (y * w + x) * 4
                px[o] = c.2; px[o + 1] = c.1; px[o + 2] = c.0
            }
        }
        return px
    }

    private func detect(_ px: [UInt8]) -> WhiteBallDetector.Result {
        px.withUnsafeBytes { WhiteBallDetector().detect(bgra: $0, width: w, height: h, bytesPerRow: w * 4, step: 2) }
    }

    func testFindsWhiteBallOnGrass() throws {
        let r = detect(scene(grass, discs: [(60, 70, 8, white)]))
        XCTAssertEqual(r.candidates.count, 1)
        let b = try XCTUnwrap(r.candidates.first)
        XCTAssertEqual(b.centerX, 60, accuracy: 1.5)
        XCTAssertEqual(b.centerY, 70, accuracy: 1.5)
        XCTAssertEqual(b.radiusPixels, 8, accuracy: 2)
        XCTAssertGreaterThan(b.colorMatchFraction, 0.8, "confidence")
        XCTAssertEqual(r.masks.width, 100)
        XCTAssertTrue(r.masks.color.contains(1), "highlight mask marks the ball")
    }

    func testFindsDistantSmallBall() {
        XCTAssertEqual(detect(scene(grass, discs: [(140, 100, 3, white)])).candidates.count, 1)
    }

    func testRejectsPaintedLineButKeepsBall() {
        let r = detect(scene(grass, discs: [(60, 70, 8, white)], rects: [(0, 110, 200, 114, white)]))
        XCTAssertEqual(r.candidates.count, 1)
        XCTAssertEqual(r.candidates.first?.centerY ?? 0, 70, accuracy: 1.5)
    }

    func testRejectsSkyEdge() {
        XCTAssertTrue(detect(scene(grass, skyRows: 60)).candidates.isEmpty)
    }

    func testRejectsBallOnSandAndCartPath() {
        XCTAssertTrue(detect(scene((217, 196, 152), discs: [(60, 70, 8, white)])).candidates.isEmpty, "sand")
        XCTAssertTrue(detect(scene((120, 120, 120), discs: [(60, 70, 8, white)])).candidates.isEmpty, "cart path: no grass around it")
    }

    func testRejectsGreyDisc() {
        XCTAssertTrue(detect(scene(grass, discs: [(60, 70, 8, (150, 150, 150))])).candidates.isEmpty)
    }

    func testWhitePresetRejectsGrassButNotSky() {
        let range = BallColorProfile.white.range
        XCTAssertFalse(range.contains(HSV(r: 0.24, g: 0.55, b: 0.2)), "grass")
        XCTAssertTrue(range.contains(HSV(r: 0.92, g: 0.94, b: 0.96)), "why the extra tests exist: sky passes the colour mask")
        XCTAssertEqual(BallColorProfile.white.preset, .white)
    }
}
