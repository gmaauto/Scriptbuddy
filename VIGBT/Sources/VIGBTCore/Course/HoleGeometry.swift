import Foundation

public enum LayoutSide: String, Codable, Sendable {
    case left, right, crossing
}

/// A hazard's extent along the playing line.
public struct HazardSpan: Equatable, Sendable {
    public var kind: HazardKind
    /// Distances along the playing line, meters (relative to whatever origin was requested).
    public var start: Double
    public var end: Double
    public var side: LayoutSide

    public init(kind: HazardKind, start: Double, end: Double, side: LayoutSide) {
        self.kind = kind
        self.start = start
        self.end = end
        self.side = side
    }
}

public struct Dogleg: Equatable, Sendable {
    public var along: Double
    public var side: LayoutSide
    public var angleDeg: Double
}

/// Measurements along a hole's playing line in a local East/North frame (meters).
/// Positions are expressed as (along, lateral): distance along the line from its start, and
/// signed offset from it (positive = right of the line when facing the green).
public struct HoleGeometry: Sendable {
    public let hole: Hole
    public let origin: GeoCoordinate
    private let points: [(e: Double, n: Double)]
    private let cumulative: [Double]

    public init?(hole: Hole) {
        let line = hole.playingLine
        guard line.count >= 2 else { return nil }
        self.hole = hole
        origin = line[0]
        points = line.map { GeoMath.enuOffset(of: $0, from: line[0]) }
        var cum: [Double] = [0]
        for i in 1..<points.count {
            let de = points[i].e - points[i - 1].e
            let dn = points[i].n - points[i - 1].n
            cum.append(cum[i - 1] + (de * de + dn * dn).squareRoot())
        }
        cumulative = cum
    }

    /// Length of the playing line, meters.
    public var length: Double { cumulative.last ?? 0 }

    /// True-north bearing from the start of the line to its end (used to rotate the layout so the green is up).
    public var bearingDeg: Double {
        let a = points[0], b = points[points.count - 1]
        return CameraPose.heading(east: b.e - a.e, north: b.n - a.n)
    }

    /// Projects a coordinate onto the playing line. The first and last segments are extended so points
    /// behind the tee or past the green get negative / beyond-length `along` values.
    public func project(_ c: GeoCoordinate) -> (along: Double, lateral: Double) {
        let o = GeoMath.enuOffset(of: c, from: origin)
        let p = (e: o.east, n: o.north)
        var best: (dist: Double, along: Double, lateral: Double)?
        let last = points.count - 2
        for i in 0...last {
            let a = points[i], b = points[i + 1]
            let de = b.e - a.e, dn = b.n - a.n
            let len = (de * de + dn * dn).squareRoot()
            guard len > 0 else { continue }
            let ue = de / len, un = dn / len
            let pe = p.e - a.e, pn = p.n - a.n
            var t = pe * ue + pn * un
            if i > 0 { t = max(0, t) }
            if i < last { t = min(len, t) }
            let qe = a.e + ue * t, qn = a.n + un * t
            let dist = ((p.e - qe) * (p.e - qe) + (p.n - qn) * (p.n - qn)).squareRoot()
            // Right-hand normal of (ue, un) is (un, −ue).
            let lateral = pe * un - pn * ue
            if best == nil || dist < best!.dist {
                best = (dist, cumulative[i] + t, lateral)
            }
        }
        return best.map { ($0.along, $0.lateral) } ?? (0, 0)
    }

    /// Playing length from a given tee (or any point) to the end of the line.
    public func remainingLength(from c: GeoCoordinate) -> Double {
        max(0, length - project(c).along)
    }

    /// Hazard extents relative to `originAlong` (e.g. the golfer's projected position).
    public func hazardSpans(relativeTo originAlong: Double = 0) -> [HazardSpan] {
        hole.hazards.compactMap { (h: Hazard) -> HazardSpan? in
            let proj = h.outline.map(project)
            guard let minA = proj.map({ $0.along }).min(), let maxA = proj.map({ $0.along }).max() else { return nil }
            let lats = proj.map { $0.lateral }
            let lo = lats.min() ?? 0, hi = lats.max() ?? 0
            let side: LayoutSide
            if lo < 0, hi > 0 {
                side = .crossing
            } else {
                side = (lo + hi) / 2 > 0 ? .right : .left
            }
            return HazardSpan(kind: h.kind, start: minA - originAlong, end: maxA - originAlong, side: side)
        }
        .sorted { $0.start < $1.start }
    }

    /// Bends in the playing line of at least `minimumAngleDeg`.
    public func doglegs(minimumAngleDeg: Double = 15) -> [Dogleg] {
        guard points.count >= 3 else { return [] }
        var out: [Dogleg] = []
        for i in 1..<(points.count - 1) {
            let a = points[i - 1], b = points[i], c = points[i + 1]
            let h1 = atan2(b.e - a.e, b.n - a.n)
            let h2 = atan2(c.e - b.e, c.n - b.n)
            let turn = Units.signedAngle(Units.degrees(h2 - h1)) // + = clockwise = right
            if abs(turn) >= minimumAngleDeg {
                out.append(Dogleg(along: cumulative[i], side: turn > 0 ? .right : .left, angleDeg: abs(turn)))
            }
        }
        return out
    }

    /// Converts a coordinate to layout-space meters: x right, y toward the green, origin at the line start.
    public func layoutPoint(_ c: GeoCoordinate) -> (x: Double, y: Double) {
        let o = GeoMath.enuOffset(of: c, from: origin)
        let p = (e: o.east, n: o.north)
        let r = Units.radians(bearingDeg)
        // Rotate so the hole bearing points up (+y).
        return (p.e * cos(r) - p.n * sin(r), p.e * sin(r) + p.n * cos(r))
    }
}
