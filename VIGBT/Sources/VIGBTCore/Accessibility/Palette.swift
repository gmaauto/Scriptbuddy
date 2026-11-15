import Foundation

/// sRGB colour, 8 bits per channel.
public struct RGB: Codable, Equatable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// "#RRGGBB"
    public init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt32(s, radix: 16) ?? 0
        self.init(UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
    }

    /// WCAG 2.x relative luminance.
    public var relativeLuminance: Double {
        func lin(_ c: UInt8) -> Double {
            let x = Double(c) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio, 1…21.
    public func contrast(with other: RGB) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// WCAG 2.2 thresholds VIGBT holds itself to (stricter than the AA legal baseline).
public enum ContrastRequirement {
    /// Text and icons that carry text meaning: AAA (1.4.6).
    public static let text = 7.0
    /// Graphical objects and UI component boundaries: AA (1.4.11).
    public static let nonText = 3.0
}

public enum Theme: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Yellow/white on black. Default: best for most low-vision users and glare outdoors at dusk.
    case highContrastDark
    /// Black/blue on white. Many users with cataracts or in bright sun prefer dark text on light.
    case highContrastLight
    /// Follows the system appearance, using the matching high-contrast palette.
    case system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .highContrastDark: return "High contrast dark"
        case .highContrastLight: return "High contrast light"
        case .system: return "Match system"
        }
    }
}

/// Every colour the app draws with. No view uses a colour outside this palette.
/// The rules are enforced by unit tests (`AccessibilityTests`).
public struct ThemePalette: Equatable, Sendable {
    // Surfaces
    public var background: RGB
    public var surface: RGB
    // Text (≥ 7:1 on background and surface)
    public var text: RGB
    public var secondaryText: RGB
    public var accent: RGB
    public var warning: RGB
    public var success: RGB
    /// Text/icon colour on an accent-filled button (≥ 7:1 on accent).
    public var onAccent: RGB
    /// Fill of secondary buttons; always drawn with a `text`-coloured border, since the fill alone is < 3:1.
    public var secondaryButton: RGB
    // Map (≥ 3:1 on background; every shape also gets a text-colour outline and a label)
    public var water: RGB
    public var bunker: RGB
    public var green: RGB
    public var fairway: RGB
    public var outOfBounds: RGB
    public var pin: RGB
    public var tracer: RGB { accent }

    public static let highContrastDark = ThemePalette(
        background: RGB(hex: "#000000"), surface: RGB(hex: "#262626"),
        text: RGB(hex: "#FFFFFF"), secondaryText: RGB(hex: "#D9D9D9"), accent: RGB(hex: "#FFD60A"),
        warning: RGB(hex: "#FFA94D"), success: RGB(hex: "#5BE37D"), onAccent: RGB(hex: "#000000"),
        secondaryButton: RGB(hex: "#3D3D3D"),
        water: RGB(hex: "#5AB0FF"), bunker: RGB(hex: "#F2D98C"), green: RGB(hex: "#4CD964"),
        fairway: RGB(hex: "#6E6E6E"), outOfBounds: RGB(hex: "#FF7A7A"), pin: RGB(hex: "#FF6B6B"))

    public static let highContrastLight = ThemePalette(
        background: RGB(hex: "#FFFFFF"), surface: RGB(hex: "#EDEDED"),
        text: RGB(hex: "#000000"), secondaryText: RGB(hex: "#333333"), accent: RGB(hex: "#0033B3"),
        warning: RGB(hex: "#7A2B00"), success: RGB(hex: "#00561F"), onAccent: RGB(hex: "#FFFFFF"),
        secondaryButton: RGB(hex: "#D6D6D6"),
        water: RGB(hex: "#0047B3"), bunker: RGB(hex: "#7A5C00"), green: RGB(hex: "#0B6E2E"),
        fairway: RGB(hex: "#8A8A8A"), outOfBounds: RGB(hex: "#A3001B"), pin: RGB(hex: "#B3001E"))

    public static func palette(for theme: Theme, systemIsDark: Bool) -> ThemePalette {
        switch theme {
        case .highContrastDark: return .highContrastDark
        case .highContrastLight: return .highContrastLight
        case .system: return systemIsDark ? .highContrastDark : .highContrastLight
        }
    }

    /// Named colour pairs that must meet `ContrastRequirement.text`.
    public var textPairs: [(String, RGB, RGB)] {
        var out: [(String, RGB, RGB)] = []
        for (name, fg) in [("text", text), ("secondaryText", secondaryText), ("accent", accent),
                           ("warning", warning), ("success", success)] {
            out.append(("\(name)/background", fg, background))
            out.append(("\(name)/surface", fg, surface))
        }
        out.append(("onAccent/accent", onAccent, accent))
        out.append(("text/secondaryButton", text, secondaryButton))
        return out
    }

    /// Named colour pairs that must meet `ContrastRequirement.nonText`.
    public var nonTextPairs: [(String, RGB, RGB)] {
        [("water", water), ("bunker", bunker), ("green", green), ("fairway", fairway),
         ("outOfBounds", outOfBounds), ("pin", pin), ("tracer", tracer), ("outline", text)]
            .map { ("\($0.0)/background", $0.1, background) }
    }
}
