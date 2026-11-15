import Foundation

/// One element of the non-visual hole description (Phase 5.4). Each is its own VoiceOver element.
public struct LayoutFeature: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case dogleg
        case hazard(HazardKind)
        case green
        case pin
    }

    public var kind: Kind
    public var side: LayoutSide?
    /// Distances from the golfer along the playing line, meters.
    public var from: Double
    public var to: Double?
    public var text: String

    public var id: String { "\(kind)-\(Int(from))-\(side?.rawValue ?? "")" }
}

public struct HoleDescription: Equatable, Sendable {
    public var summary: String
    public var features: [LayoutFeature]

    /// Everything, in order, as one announcement.
    public var fullText: String { ([summary] + features.map(\.text)).joined(separator: " ") }
}

public enum HoleDescriber {
    /// - Parameters:
    ///   - teeName: tee set used for the hole length.
    ///   - golfer: current position; distances are measured from here (from the tee when nil).
    public static func describe(hole: Hole, teeName: String?, golfer: GeoCoordinate?) -> HoleDescription {
        var summary = "Hole \(hole.number)"
        if let par = hole.par { summary += ", par \(par)" }
        guard let geo = HoleGeometry(hole: hole) else {
            return HoleDescription(summary: summary + ". This hole has not been mapped yet.", features: [])
        }
        let tee = hole.tee(named: teeName)
        let length = tee.map { geo.remainingLength(from: $0.coordinate) } ?? geo.length
        summary += ", \(yd(length)) yards"
        if let si = hole.strokeIndex { summary += ", stroke index \(si)" }
        summary += "."

        let origin = golfer.map { geo.project($0).along } ?? tee.map { geo.project($0.coordinate).along } ?? 0
        var features: [LayoutFeature] = []

        for d in geo.doglegs() where d.along > origin {
            let from = d.along - origin
            let sharp = d.angleDeg >= 35 ? "sharply " : ""
            features.append(LayoutFeature(kind: .dogleg, side: d.side, from: from, to: nil,
                                          text: "Fairway bends \(sharp)\(d.side.rawValue) at \(yd(from)) yards."))
        }

        for h in geo.hazardSpans(relativeTo: origin) where h.end > 0 {
            let name = h.kind.spokenName
            let place: String
            switch h.side {
            case .crossing: place = "\(name) across the line"
            case .left: place = "\(name) on the left"
            case .right: place = "\(name) on the right"
            }
            let start = max(0, h.start)
            let range = abs(h.end - start) < Units.meters(fromYards: 5)
                ? "at \(yd(start)) yards"
                : "from \(yd(start)) to \(yd(h.end)) yards"
            features.append(LayoutFeature(kind: .hazard(h.kind), side: h.side, from: start, to: h.end,
                                          text: "\(place) \(range)."))
        }

        if let g = hole.green {
            let front = geo.project(g.front).along - origin
            let back = geo.project(g.back).along - origin
            var text = "Green: front \(yd(front)), centre \(yd(geo.project(g.center).along - origin))"
            text += ", back \(yd(back)) yards."
            if back - front >= Units.meters(fromYards: 3) { text += " \(yd(back - front)) yards deep." }
            features.append(LayoutFeature(kind: .green, side: nil, from: front, to: back, text: text))
        }
        if let pin = hole.pin {
            let d = golfer.map { GeoMath.distance(from: $0, to: pin) } ?? (geo.project(pin).along - origin)
            features.append(LayoutFeature(kind: .pin, side: nil, from: d, to: nil,
                                          text: "Pin \(yd(d)) yards."))
        }
        features.sort { $0.from < $1.from }
        return HoleDescription(summary: summary, features: features)
    }

    static func yd(_ meters: Double) -> String { Readout.whole(Units.yards(fromMeters: max(0, meters))) }
}

/// Phase 5.2: hole changes from GPS.
public enum CourseLocator {
    /// The hole whose tee box is within `radius` of the golfer, preferring `expected` if it qualifies.
    public static func holeOnTee(course: GolfCourse, position: GeoCoordinate, radiusMeters: Double = 25,
                                 expected: Int? = nil) -> Int? {
        var best: (Int, Double)?
        for h in course.holes {
            for t in h.tees {
                let d = GeoMath.distance(from: position, to: t.coordinate)
                guard d <= radiusMeters else { continue }
                if h.number == expected { return h.number }
                if d < (best?.1 ?? .infinity) { best = (h.number, d) }
            }
        }
        return best?.0
    }

    /// Distance from the golfer to the hole's target (pin, else green centre).
    public static func distanceToPin(hole: Hole, from position: GeoCoordinate) -> Double? {
        hole.target.map { GeoMath.distance(from: position, to: $0) }
    }

    /// Hazard spans measured from the golfer's position along the hole.
    public static func hazards(hole: Hole, from position: GeoCoordinate) -> [HazardSpan] {
        guard let g = HoleGeometry(hole: hole) else { return [] }
        return g.hazardSpans(relativeTo: g.project(position).along)
    }
}
