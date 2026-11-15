import XCTest
@testable import VIGBTCore

final class AccessibilityTests: XCTestCase {
    func testContrastMath() {
        XCTAssertEqual(RGB(hex: "#000000").contrast(with: RGB(hex: "#FFFFFF")), 21, accuracy: 0.01)
        XCTAssertEqual(RGB(hex: "#777777").contrast(with: RGB(hex: "#FFFFFF")), 4.48, accuracy: 0.01)
        XCTAssertEqual(RGB(hex: "#FFD60A"), RGB(255, 214, 10))
    }

    /// WCAG 2.2 AAA (7:1) for all text, AA (3:1) for graphics, in every theme.
    func testEveryThemeMeetsContrastRequirements() {
        for theme in [ThemePalette.highContrastDark, .highContrastLight] {
            for (name, fg, bg) in theme.textPairs {
                XCTAssertGreaterThanOrEqual(fg.contrast(with: bg), ContrastRequirement.text, "text pair \(name)")
            }
            for (name, fg, bg) in theme.nonTextPairs {
                XCTAssertGreaterThanOrEqual(fg.contrast(with: bg), ContrastRequirement.nonText, "graphic \(name)")
            }
        }
    }

    func testSystemThemeFollowsAppearance() {
        XCTAssertEqual(ThemePalette.palette(for: .system, systemIsDark: true), .highContrastDark)
        XCTAssertEqual(ThemePalette.palette(for: .system, systemIsDark: false), .highContrastLight)
        XCTAssertEqual(ThemePalette.palette(for: .highContrastLight, systemIsDark: true), .highContrastLight)
    }

    func testBallHighlightPaintsBallAndRing() {
        let w = 40, h = 30
        var color = [UInt8](repeating: 0, count: w * h)
        color[15 * w + 20] = 1
        let masks = FrameMasks(width: w, height: h, step: 2, luma: [UInt8](repeating: 200, count: w * h), color: color)
        let ball = DetectionCandidate(centerX: 41, centerY: 31, width: 4, height: 4, colorMatchFraction: 1)
        let p = ThemePalette.highContrastDark
        let img = BallHighlight.render(masks: masks, ball: ball, highlight: p.accent, ring: p.pin, background: p.background)
        XCTAssertEqual(img.rgba.count, w * h * 4)
        let ballPx = (15 * w + 20) * 4
        XCTAssertEqual(Array(img.rgba[ballPx..<ballPx + 3]), [p.accent.r, p.accent.g, p.accent.b])
        XCTAssertEqual(img.rgba[0], 50, "scene dimmed to 25% toward black")
        XCTAssertTrue(stride(from: 0, to: img.rgba.count, by: 4).contains {
            img.rgba[$0] == p.pin.r && img.rgba[$0 + 1] == p.pin.g && img.rgba[$0 + 2] == p.pin.b
        }, "ring drawn around the ball")
        // Light theme dims toward white instead.
        let light = BallHighlight.render(masks: masks, ball: nil, highlight: p.accent, ring: p.pin,
                                         background: ThemePalette.highContrastLight.background)
        XCTAssertEqual(light.rgba[0], 241)
    }
}

final class VersioningTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    func testVersionIsConsistentEverywhere() throws {
        let v = VIGBTVersion.string
        XCTAssertEqual(try read("VERSION").trimmingCharacters(in: .whitespacesAndNewlines), v)
        XCTAssertTrue(try read("CHANGELOG.md").contains("## [\(v)]"), "CHANGELOG needs an entry for \(v)")
        XCTAssertTrue(try read("SPEC.md").contains("Document version: \(v)"), "SPEC.md header must state \(v)")
        XCTAssertTrue(try read("App/project.yml").contains("MARKETING_VERSION: \"\(v)\""))
        XCTAssertTrue(try read("App/project.yml").contains("CURRENT_PROJECT_VERSION: \"\(VIGBTVersion.build)\""))
    }

    func testSemanticVersionShape() {
        let parts = VIGBTVersion.string.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }

    func testEnvelopeRoundTripAndLegacyFiles() throws {
        let bag = ClubBag.standard
        let data = try DataFormat.encode(bag, format: DataFormat.bag)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"formatVersion\":2"))
        XCTAssertTrue(text.contains("\"appVersion\":\"\(VIGBTVersion.string)\""))
        XCTAssertEqual(try DataFormat.decode(ClubBag.self, from: data, supported: DataFormat.bag), bag)

        // Format 1 (bare payload, written by ≤ 0.5.0) still loads.
        let legacy = try JSONEncoder().encode(bag)
        XCTAssertEqual(try DataFormat.decode(ClubBag.self, from: legacy, supported: DataFormat.bag), bag)
    }

    func testNewerFormatIsRefusedNotOverwritten() throws {
        let data = try DataFormat.encode(ClubBag.standard, format: 99)
        XCTAssertThrowsError(try DataFormat.decode(ClubBag.self, from: data, supported: DataFormat.bag)) {
            XCTAssertEqual($0 as? DataFormat.DecodeError, .newerFormat(found: 99, supported: 2))
        }
    }
}
