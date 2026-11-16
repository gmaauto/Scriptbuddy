import Foundation

/// What the ball lands on, from the course map (SPEC §12.8).
public enum Surface: String, Codable, CaseIterable, Sendable {
    case fairway, rough, green, bunker, water

    /// Spoken phrase, e.g. "in the rough".
    public var phrase: String {
        switch self {
        case .fairway: return "on the fairway"
        case .rough: return "in the rough"
        case .green: return "on the green"
        case .bunker: return "in a bunker"
        case .water: return "in the water"
        }
    }

    /// Bounce and roll for this surface, relative to the (learned) fairway model.
    public func ground(from fairway: GroundModel) -> GroundModel {
        var g = fairway
        switch self {
        case .fairway: break
        case .rough:
            g.rollingFriction *= 1.8
            g.restitution *= 0.8
        case .green:
            g.rollingFriction *= 0.5
            g.restitution *= 0.85
        case .bunker:
            // Sand swallows the ball: almost no bounce or roll.
            g.restitution = 0.05
            g.rollingFriction = 5
        case .water:
            g.restitution = 0
            g.rollingFriction = 50
        }
        return g
    }
}

/// The current hole's mapped surfaces (OpenStreetMap or marked on site), used to pick the roll physics
/// for the predicted landing point. Anything mapped as none of these counts as rough when the hole has
/// mapped fairways, and as fairway when it has none (so an unmapped hole behaves as before 0.12.0).
///
/// Monte Carlo (100,000 shots, fairways 13–22 m half-width): p90 error 31.3 → 28.6 yd, search coverage
/// 87.7% → 89.2%.
public struct SurfaceMap: Sendable {
    public var fairways: [[GeoCoordinate]]
    public var greens: [[GeoCoordinate]]
    public var bunkers: [[GeoCoordinate]]
    public var water: [[GeoCoordinate]]

    public init(fairways: [[GeoCoordinate]] = [], greens: [[GeoCoordinate]] = [],
                bunkers: [[GeoCoordinate]] = [], water: [[GeoCoordinate]] = []) {
        self.fairways = fairways
        self.greens = greens
        self.bunkers = bunkers
        self.water = water
    }

    public init(hole: Hole) {
        self.init(fairways: hole.fairways,
                  greens: hole.green.map { $0.outline.count >= 3 ? [$0.outline] : [] } ?? [],
                  bunkers: hole.hazards.filter { $0.kind == .bunker && $0.outline.count >= 3 }.map(\.outline),
                  water: hole.hazards.filter { $0.kind == .water && $0.outline.count >= 3 }.map(\.outline))
    }

    public var isEmpty: Bool { fairways.isEmpty && greens.isEmpty && bunkers.isEmpty && water.isEmpty }

    /// Surface at a point. Hazards win over greens, greens over fairways.
    public func surface(at c: GeoCoordinate) -> Surface {
        if water.contains(where: { Self.contains($0, c) }) { return .water }
        if bunkers.contains(where: { Self.contains($0, c) }) { return .bunker }
        if greens.contains(where: { Self.contains($0, c) }) { return .green }
        if fairways.contains(where: { Self.contains($0, c) }) { return .fairway }
        return fairways.isEmpty ? .fairway : .rough
    }

    /// Ray-casting point-in-polygon in a local East/North frame around the point.
    static func contains(_ polygon: [GeoCoordinate], _ c: GeoCoordinate) -> Bool {
        guard polygon.count >= 3 else { return false }
        let pts = polygon.map { GeoMath.enuOffset(of: $0, from: c) }
        var inside = false
        var j = pts.count - 1
        for i in 0..<pts.count {
            let a = pts[i], b = pts[j]
            if (a.north > 0) != (b.north > 0) {
                let x = a.east + (0 - a.north) * (b.east - a.east) / (b.north - a.north)
                if x > 0 { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
