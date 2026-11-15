import Foundation

/// A single mapped golf feature, independent of the file format it came from.
public struct CourseFeature: Sendable {
    /// The `golf=*` value: hole, tee, green, pin, fairway, bunker, water_hazard, …
    public var kind: String
    public var tags: [String: String]
    public var points: [GeoCoordinate]

    public init(kind: String, tags: [String: String], points: [GeoCoordinate]) {
        self.kind = kind
        self.tags = tags
        self.points = points
    }

    var centroid: GeoCoordinate {
        let n = Double(max(1, points.count))
        return GeoCoordinate(latitude: points.reduce(0) { $0 + $1.latitude } / n,
                             longitude: points.reduce(0) { $0 + $1.longitude } / n)
    }
}

public enum CourseParseError: Error, Equatable {
    case invalidJSON
    case noHoles
}

// MARK: - OpenStreetMap via Overpass

/// Builds Overpass QL queries and parses `out geom` / `out center` JSON. Everything here is
/// open data under the ODbL; the app must show `GolfCourse.osmAttribution` wherever it is used.
public enum OverpassParser {
    public static let defaultEndpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    /// Golf courses within `radiusMeters` of a point.
    public static func nearbyQuery(center: GeoCoordinate, radiusMeters: Double) -> String {
        let r = Int(radiusMeters.rounded())
        return "[out:json][timeout:25];"
            + "(way[\"leisure\"=\"golf_course\"](around:\(r),\(center.latitude),\(center.longitude));"
            + "relation[\"leisure\"=\"golf_course\"](around:\(r),\(center.latitude),\(center.longitude)););"
            + "out tags center;"
    }

    /// Every `golf=*` feature inside one course's boundary. `id` is "way/123" or "relation/45".
    public static func courseQuery(id: String) -> String {
        let parts = id.split(separator: "/")
        let type = parts.first.map(String.init) ?? "way"
        let num = parts.last.map(String.init) ?? "0"
        return "[out:json][timeout:90];\(type)(\(num));map_to_area->.c;nwr(area.c)[\"golf\"];out geom;"
    }

    struct LatLon: Decodable {
        let lat: Double
        let lon: Double
        var coordinate: GeoCoordinate { GeoCoordinate(latitude: lat, longitude: lon) }
    }

    struct Member: Decodable {
        let role: String?
        let geometry: [LatLon?]?
    }

    struct Element: Decodable {
        let type: String
        let id: Int64
        let lat: Double?
        let lon: Double?
        let center: LatLon?
        let geometry: [LatLon?]?
        let members: [Member]?
        let tags: [String: String]?
    }

    struct Response: Decodable {
        let elements: [Element]
    }

    public static func parseSummaries(_ data: Data, from position: GeoCoordinate?) throws -> [CourseSummary] {
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { throw CourseParseError.invalidJSON }
        let out: [CourseSummary] = r.elements.compactMap { (e: Element) -> CourseSummary? in
            let c: GeoCoordinate?
            if let center = e.center { c = center.coordinate }
            else if let lat = e.lat, let lon = e.lon { c = GeoCoordinate(latitude: lat, longitude: lon) }
            else { c = nil }
            guard let center = c else { return nil }
            let name = e.tags?["name"] ?? "Unnamed golf course"
            let d = position.map { GeoMath.distance(from: $0, to: center) }
            return CourseSummary(id: "\(e.type)/\(e.id)", name: name, center: center, distanceMeters: d)
        }
        return out.sorted { ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity) }
    }

    public static func parseFeatures(_ data: Data) throws -> [CourseFeature] {
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { throw CourseParseError.invalidJSON }
        return r.elements.compactMap { (e: Element) -> CourseFeature? in
            guard let tags = e.tags, let kind = tags["golf"] else { return nil }
            var pts: [GeoCoordinate] = []
            if let lat = e.lat, let lon = e.lon {
                pts = [GeoCoordinate(latitude: lat, longitude: lon)]
            } else if let g = e.geometry {
                pts = g.compactMap { $0?.coordinate }
            } else if let members = e.members {
                // Multipolygon: use the outer rings.
                pts = members.filter { ($0.role ?? "outer") == "outer" }
                    .flatMap { ($0.geometry ?? []).compactMap { $0?.coordinate } }
            }
            guard !pts.isEmpty else { return nil }
            return CourseFeature(kind: kind, tags: tags, points: pts)
        }
    }
}

// MARK: - GeoJSON import

/// Parses a GeoJSON FeatureCollection whose features carry OSM-style `golf` properties
/// (as exported by OSM editors and tools such as overpass-turbo).
public enum GeoJSONParser {
    public static func parse(_ data: Data) throws -> (name: String?, features: [CourseFeature]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { throw CourseParseError.invalidJSON }
        var name = root["name"] as? String
        var out: [CourseFeature] = []
        for f in features {
            let rawProps = f["properties"] as? [String: Any] ?? [:]
            var tags: [String: String] = [:]
            for (k, v) in rawProps { tags[k] = (v as? String) ?? "\(v)" }
            if tags["leisure"] == "golf_course", name == nil { name = tags["name"] }
            guard let kind = tags["golf"], let geom = f["geometry"] as? [String: Any],
                  let type = geom["type"] as? String else { continue }
            let pts = coordinates(type: type, raw: geom["coordinates"])
            if !pts.isEmpty { out.append(CourseFeature(kind: kind, tags: tags, points: pts)) }
        }
        return (name, out)
    }

    /// Number bridging differs between Darwin and Linux Foundation, so try each representation.
    private static func number(_ x: Any) -> Double? {
        if let d = x as? Double { return d }
        if let i = x as? Int { return Double(i) }
        if let n = x as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func point(_ raw: Any?) -> GeoCoordinate? {
        guard let a = raw as? [Any], a.count >= 2,
              let lon = number(a[0]), let lat = number(a[1]) else { return nil }
        return GeoCoordinate(latitude: lat, longitude: lon)
    }

    private static func line(_ raw: Any?) -> [GeoCoordinate] {
        (raw as? [Any] ?? []).compactMap(point)
    }

    private static func coordinates(type: String, raw: Any?) -> [GeoCoordinate] {
        switch type {
        case "Point": return point(raw).map { [$0] } ?? []
        case "LineString": return line(raw)
        case "Polygon": return line((raw as? [Any])?.first)
        case "MultiPolygon": return line(((raw as? [Any])?.first as? [Any])?.first)
        default: return []
        }
    }
}

// MARK: - Assembly

/// Turns loose features into holes: tees are attached to the nearest hole start, greens to the
/// nearest hole end, pins to their green, fairways and hazards to the nearest playing line.
public enum CourseAssembler {
    public static func assemble(id: String, name: String, features: [CourseFeature], source: CourseSource,
                                attribution: String? = nil) throws -> GolfCourse {
        var holes: [Hole] = []
        var nextNumber = 1
        for f in features where f.kind == "hole" && f.points.count >= 2 {
            let number = f.tags["ref"].flatMap { Int($0) } ?? nextNumber
            nextNumber = max(nextNumber, number + 1)
            holes.append(Hole(number: number, par: f.tags["par"].flatMap { Int($0) },
                              strokeIndex: f.tags["handicap"].flatMap { Int($0) }, centerline: f.points))
        }
        guard !holes.isEmpty else { throw CourseParseError.noHoles }

        func nearestHole(to c: GeoCoordinate, end: Bool, within limit: Double) -> Int? {
            var best: (Int, Double)?
            for (i, h) in holes.enumerated() {
                guard let p = end ? h.centerline.last : h.centerline.first else { continue }
                let d = GeoMath.distance(from: c, to: p)
                if d <= limit, d < (best?.1 ?? .infinity) { best = (i, d) }
            }
            return best?.0
        }

        // Greens and tees.
        for f in features where f.kind == "green" {
            guard let i = nearestHole(to: f.centroid, end: true, within: 150) else { continue }
            holes[i].green = GreenGeometry(front: f.centroid, center: f.centroid, back: f.centroid, outline: f.points)
        }
        for f in features where f.kind == "tee" {
            guard let i = nearestHole(to: f.centroid, end: false, within: 150) else { continue }
            let name = f.tags["tee"] ?? f.tags["name"] ?? f.tags["colour"]?.capitalized ?? "Tee"
            holes[i].tees.append(TeeBox(name: name.capitalized, coordinate: f.centroid))
        }
        for i in holes.indices where holes[i].tees.isEmpty {
            holes[i].tees = [TeeBox(name: "Tee", coordinate: holes[i].centerline[0])]
        }

        // Green front/back along the playing line.
        for i in holes.indices {
            guard var g = holes[i].green, let geo = HoleGeometry(hole: holes[i]), !g.outline.isEmpty else { continue }
            let proj = g.outline.map { ($0, geo.project($0).along) }
            if let f = proj.min(by: { $0.1 < $1.1 }) { g.front = f.0 }
            if let b = proj.max(by: { $0.1 < $1.1 }) { g.back = b.0 }
            holes[i].green = g
        }

        // Pins: by ref, else the nearest green.
        for f in features where f.kind == "pin" {
            let c = f.centroid
            if let ref = f.tags["ref"].flatMap({ Int($0) }), let i = holes.firstIndex(where: { $0.number == ref }) {
                holes[i].pin = c
                continue
            }
            let candidates = holes.indices.compactMap { i -> (Int, Double)? in
                guard let g = holes[i].green else { return nil }
                return (i, GeoMath.distance(from: c, to: g.center))
            }
            if let best = candidates.min(by: { $0.1 < $1.1 }), best.1 <= 60 { holes[best.0].pin = c }
        }

        // Fairways and hazards: nearest playing line.
        let geometries = holes.map { HoleGeometry(hole: $0) }
        func nearestLine(to pts: [GeoCoordinate], lateralLimit: Double) -> Int? {
            var best: (Int, Double)?
            for (i, g) in geometries.enumerated() {
                guard let g else { continue }
                let proj = pts.map(g.project)
                let lat = proj.map { abs($0.lateral) }.min() ?? .infinity
                let alongOK = proj.contains { $0.along >= -20 && $0.along <= g.length + 20 }
                if alongOK, lat <= lateralLimit, lat < (best?.1 ?? .infinity) { best = (i, lat) }
            }
            return best?.0
        }
        for f in features {
            switch f.kind {
            case "fairway":
                if let i = nearestLine(to: f.points, lateralLimit: 80) { holes[i].fairways.append(f.points) }
            case "bunker":
                if let i = nearestLine(to: f.points, lateralLimit: 60) { holes[i].hazards.append(Hazard(kind: .bunker, outline: f.points)) }
            case "water_hazard", "lateral_water_hazard":
                if let i = nearestLine(to: f.points, lateralLimit: 60) { holes[i].hazards.append(Hazard(kind: .water, outline: f.points)) }
            case "out_of_bounds":
                if let i = nearestLine(to: f.points, lateralLimit: 60) { holes[i].hazards.append(Hazard(kind: .outOfBounds, outline: f.points)) }
            default:
                break
            }
        }

        let all = holes.flatMap(\.centerline)
        let n = Double(all.count)
        let center = GeoCoordinate(latitude: all.reduce(0) { $0 + $1.latitude } / n,
                                   longitude: all.reduce(0) { $0 + $1.longitude } / n)
        return GolfCourse(id: id, name: name, location: center, holes: holes, source: source,
                          attribution: attribution)
    }
}
