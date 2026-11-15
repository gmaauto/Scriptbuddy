import Foundation
import Observation
import VIGBTCore

/// Phase 5.1: finds, downloads, imports and caches courses. Open data only:
/// OpenStreetMap through a public Overpass instance (once per course), GeoJSON imports, or on-site marking.
@MainActor
@Observable
final class CourseService {
    enum CourseError: LocalizedError {
        case network(String)
        case noHoles

        var errorDescription: String? {
            switch self {
            case .network(let why): return "Could not reach OpenStreetMap. \(why)"
            case .noHoles: return "This course has no holes mapped in OpenStreetMap yet. You can mark it on site instead."
            }
        }
    }

    private(set) var saved: [GolfCourse] = []
    private(set) var nearby: [CourseSummary] = []
    private(set) var isLoading = false

    @ObservationIgnored private let endpoint = OverpassParser.defaultEndpoint

    static var directory: URL {
        let url = ShotStore.supportDirectory.appendingPathComponent("Courses", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() {
        loadSaved()
    }

    // MARK: Network (one request per action, fair use of the public Overpass service)

    func findNearby(_ position: GeoCoordinate, radiusMeters: Double = 15_000) async throws {
        isLoading = true
        defer { isLoading = false }
        let data = try await overpass(OverpassParser.nearbyQuery(center: position, radiusMeters: radiusMeters))
        nearby = try OverpassParser.parseSummaries(data, from: position)
    }

    func download(_ summary: CourseSummary) async throws -> GolfCourse {
        isLoading = true
        defer { isLoading = false }
        let data = try await overpass(OverpassParser.courseQuery(id: summary.id))
        let features = try OverpassParser.parseFeatures(data)
        do {
            let course = try CourseAssembler.assemble(id: "osm:\(summary.id)", name: summary.name, features: features,
                                                      source: .openStreetMap, attribution: GolfCourse.osmAttribution)
            save(course)
            return course
        } catch CourseParseError.noHoles {
            throw CourseError.noHoles
        }
    }

    private func overpass(_ query: String) async throws -> Data {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        // Generic client identification only: no user, device or location details beyond the query itself.
        req.setValue("VIGBT/1.0 (open-source accessibility golf app)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        req.httpBody = Data(body.utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw CourseError.network(http.statusCode == 429 ? "The service is busy. Try again in a minute." : "Error \(http.statusCode).")
            }
            return data
        } catch let e as CourseError {
            throw e
        } catch {
            throw CourseError.network(error.localizedDescription)
        }
    }

    // MARK: Import & marking

    func importGeoJSON(from url: URL) throws -> GolfCourse {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let parsed = try GeoJSONParser.parse(try Data(contentsOf: url))
        let name = parsed.name ?? url.deletingPathExtension().lastPathComponent
        let course = try CourseAssembler.assemble(id: "import:\(UUID().uuidString)", name: name,
                                                  features: parsed.features, source: .imported)
        save(course)
        return course
    }

    func newMarkedCourse(name: String, at position: GeoCoordinate, holes: Int) -> GolfCourse {
        let course = GolfCourse.marked(name: name, location: position, holeCount: holes)
        save(course)
        return course
    }

    // MARK: Cache

    func save(_ course: GolfCourse) {
        if let data = try? JSONEncoder().encode(course) {
            try? data.write(to: fileURL(course.id), options: .atomic)
        }
        saved.removeAll { $0.id == course.id }
        saved.insert(course, at: 0)
    }

    func delete(_ course: GolfCourse) {
        try? FileManager.default.removeItem(at: fileURL(course.id))
        saved.removeAll { $0.id == course.id }
    }

    private func loadSaved() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        saved = files.compactMap { try? JSONDecoder().decode(GolfCourse.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func fileURL(_ id: String) -> URL {
        let safe = id.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return Self.directory.appendingPathComponent(String(safe) + ".json")
    }
}
