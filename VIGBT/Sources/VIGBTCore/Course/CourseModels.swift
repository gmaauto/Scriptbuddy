import Foundation

// MARK: - Course data (Phase 5.1)

public enum CourseSource: String, Codable, Sendable {
    /// Built from OpenStreetMap `golf=*` features (ODbL).
    case openStreetMap
    /// Imported by the user from an open-format file (GeoJSON).
    case imported
    /// Marked by the golfer on the course ("Mark tee", "Mark green", "Set pin here").
    case marked
}

public enum HazardKind: String, Codable, CaseIterable, Sendable {
    case bunker, water, outOfBounds, trees

    public var spokenName: String {
        switch self {
        case .bunker: return "Bunker"
        case .water: return "Water"
        case .outOfBounds: return "Out of bounds"
        case .trees: return "Trees"
        }
    }
}

public struct Hazard: Codable, Equatable, Sendable {
    public var kind: HazardKind
    /// Polygon outline (or a single point for a node).
    public var outline: [GeoCoordinate]

    public init(kind: HazardKind, outline: [GeoCoordinate]) {
        self.kind = kind
        self.outline = outline
    }
}

public struct TeeBox: Codable, Equatable, Sendable {
    /// Tee set name, e.g. "White", "Yellow", "Red".
    public var name: String
    public var coordinate: GeoCoordinate

    public init(name: String, coordinate: GeoCoordinate) {
        self.name = name
        self.coordinate = coordinate
    }
}

public struct GreenGeometry: Codable, Equatable, Sendable {
    /// Front and back are measured along the hole's centre line.
    public var front: GeoCoordinate
    public var center: GeoCoordinate
    public var back: GeoCoordinate
    public var outline: [GeoCoordinate]
    public var elevationMeters: Double?

    public init(front: GeoCoordinate, center: GeoCoordinate, back: GeoCoordinate,
                outline: [GeoCoordinate] = [], elevationMeters: Double? = nil) {
        self.front = front
        self.center = center
        self.back = back
        self.outline = outline
        self.elevationMeters = elevationMeters
    }

    /// A green marked as a single point.
    public static func point(_ c: GeoCoordinate) -> GreenGeometry {
        GreenGeometry(front: c, center: c, back: c)
    }
}

public struct Hole: Codable, Equatable, Identifiable, Sendable {
    public var number: Int
    public var par: Int?
    public var strokeIndex: Int?
    public var tees: [TeeBox]
    public var green: GreenGeometry?
    /// Today's pin, when known. Falls back to the green centre.
    public var pin: GeoCoordinate?
    /// Playing line from the tee to the green (the OSM `golf=hole` way).
    public var centerline: [GeoCoordinate]
    public var fairways: [[GeoCoordinate]]
    public var hazards: [Hazard]

    public init(number: Int, par: Int? = nil, strokeIndex: Int? = nil, tees: [TeeBox] = [],
                green: GreenGeometry? = nil, pin: GeoCoordinate? = nil, centerline: [GeoCoordinate] = [],
                fairways: [[GeoCoordinate]] = [], hazards: [Hazard] = []) {
        self.number = number
        self.par = par
        self.strokeIndex = strokeIndex
        self.tees = tees
        self.green = green
        self.pin = pin
        self.centerline = centerline
        self.fairways = fairways
        self.hazards = hazards
    }

    public var id: Int { number }

    /// Where the golfer is aiming: today's pin, else the green centre.
    public var target: GeoCoordinate? { pin ?? green?.center }

    /// The tee for a tee set, falling back to the first tee box.
    public func tee(named name: String?) -> TeeBox? {
        if let name, let t = tees.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return t }
        return tees.first
    }

    /// The playing line, or a straight line from the first tee to the target if no line is mapped.
    public var playingLine: [GeoCoordinate] {
        if centerline.count >= 2 { return centerline }
        if let t = tees.first?.coordinate, let g = green?.center ?? pin, t != g { return [t, g] }
        return []
    }
}

public struct GolfCourse: Codable, Equatable, Identifiable, Sendable {
    /// "osm:way/123", "osm:relation/45", "import:<uuid>" or "marked:<uuid>".
    public var id: String
    public var name: String
    public var location: GeoCoordinate
    public var holes: [Hole]
    public var source: CourseSource
    public var updatedAt: Date
    /// Attribution that must be displayed with the data (ODbL for OpenStreetMap).
    public var attribution: String?

    public init(id: String, name: String, location: GeoCoordinate, holes: [Hole], source: CourseSource,
                updatedAt: Date = Date(), attribution: String? = nil) {
        self.id = id
        self.name = name
        self.location = location
        self.holes = holes.sorted { $0.number < $1.number }
        self.source = source
        self.updatedAt = updatedAt
        self.attribution = attribution
    }

    public static let osmAttribution = "© OpenStreetMap contributors (ODbL)"

    public func hole(_ number: Int) -> Hole? { holes.first { $0.number == number } }

    public var holeNumbers: [Int] { holes.map(\.number) }

    /// Tee set names in order of first appearance.
    public var teeSetNames: [String] {
        var seen: [String] = []
        for h in holes {
            for t in h.tees where !seen.contains(where: { $0.caseInsensitiveCompare(t.name) == .orderedSame }) {
                seen.append(t.name)
            }
        }
        return seen
    }

    /// An empty course to be marked on site.
    public static func marked(name: String, location: GeoCoordinate, holeCount: Int = 18) -> GolfCourse {
        GolfCourse(id: "marked:\(UUID().uuidString)", name: name, location: location,
                   holes: (1...max(1, holeCount)).map { Hole(number: $0) }, source: .marked)
    }

    // MARK: Marking on site (Phase 5.1)

    public mutating func markTee(hole number: Int, at c: GeoCoordinate, name: String = "Marked") {
        mutateHole(number) { h in
            if let i = h.tees.firstIndex(where: { $0.name == name }) {
                h.tees[i].coordinate = c
            } else {
                h.tees.append(TeeBox(name: name, coordinate: c))
            }
        }
    }

    public mutating func markGreen(hole number: Int, at c: GeoCoordinate) {
        mutateHole(number) { $0.green = .point(c) }
    }

    /// "Set pin here": stores today's pin for the hole.
    public mutating func setPin(hole number: Int, at c: GeoCoordinate) {
        mutateHole(number) { $0.pin = c }
    }

    private mutating func mutateHole(_ number: Int, _ change: (inout Hole) -> Void) {
        if let i = holes.firstIndex(where: { $0.number == number }) {
            change(&holes[i])
        } else {
            var h = Hole(number: number)
            change(&h)
            holes.append(h)
            holes.sort { $0.number < $1.number }
        }
        updatedAt = Date()
    }
}

/// A course found nearby, before its holes are downloaded.
public struct CourseSummary: Codable, Equatable, Identifiable, Sendable {
    /// OSM element reference, e.g. "way/123".
    public var id: String
    public var name: String
    public var center: GeoCoordinate
    public var distanceMeters: Double?

    public init(id: String, name: String, center: GeoCoordinate, distanceMeters: Double? = nil) {
        self.id = id
        self.name = name
        self.center = center
        self.distanceMeters = distanceMeters
    }
}

// MARK: - Round (Phase 5.2)

public struct RoundState: Codable, Equatable, Sendable {
    public var courseID: String
    public var teeSetName: String?
    public var startingHole: Int
    public var currentHole: Int
    public var holesCompleted: [Int]
    public var shotsByHole: [Int: [UUID]]

    public init(courseID: String, teeSetName: String?, startingHole: Int) {
        self.courseID = courseID
        self.teeSetName = teeSetName
        self.startingHole = startingHole
        self.currentHole = startingHole
        self.holesCompleted = []
        self.shotsByHole = [:]
    }

    /// Next hole in course order, wrapping (18 → 1, or 9 → 1 on a nine-hole course).
    public func next(in holeNumbers: [Int]) -> Int {
        guard let i = holeNumbers.firstIndex(of: currentHole), !holeNumbers.isEmpty else { return currentHole }
        return holeNumbers[(i + 1) % holeNumbers.count]
    }

    public func previous(in holeNumbers: [Int]) -> Int {
        guard let i = holeNumbers.firstIndex(of: currentHole), !holeNumbers.isEmpty else { return currentHole }
        return holeNumbers[(i - 1 + holeNumbers.count) % holeNumbers.count]
    }

    public mutating func advance(to hole: Int) {
        if !holesCompleted.contains(currentHole) { holesCompleted.append(currentHole) }
        currentHole = hole
    }

    public mutating func record(shot id: UUID) {
        shotsByHole[currentHole, default: []].append(id)
    }

    /// The round is over once every hole has been played (shotgun and back-nine starts included).
    public func isComplete(holeCount: Int) -> Bool { holesCompleted.count >= holeCount }
}
