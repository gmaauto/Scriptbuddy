import Foundation

/// Single source of truth for the product version in code. Must match `VIGBT/VERSION`,
/// the top entry of `CHANGELOG.md` and the `SPEC.md` document version. `VersioningTests` and
/// `tools/check_version.sh` enforce this. Versioning follows Semantic Versioning 2.0.0.
public enum VIGBTVersion {
    public static let string = "0.6.0"
    /// Monotonic build number (`CURRENT_PROJECT_VERSION`); +1 on every release.
    public static let build = 6
}

/// Format versions of every file VIGBT writes. Bump a number whenever that file's JSON shape changes
/// in a way an older app could not read, and add a migration in `DataFormat.decode`.
public enum DataFormat {
    /// `shots.json` — v1: bare `[ShotRecord]` (≤ 0.5.0); v2: versioned envelope (0.6.0).
    public static let shots = 2
    /// `quota.json`
    public static let quota = 2
    /// Course packages in `Courses/*.json` — v1: bare `GolfCourse`; v2: envelope.
    public static let course = 2
    /// Club bag and round state (UserDefaults blobs).
    public static let bag = 2
    public static let round = 2

    public enum DecodeError: Error, Equatable {
        /// Written by a newer app version. Do not overwrite it; ask the user to update.
        case newerFormat(found: Int, supported: Int)
        case unreadable
    }

    struct Envelope<T: Codable>: Codable {
        var formatVersion: Int
        var appVersion: String
        var savedAt: Date
        var payload: T
    }

    struct Header: Decodable {
        var formatVersion: Int
    }

    public static func encode<T: Codable>(_ value: T, format: Int) throws -> Data {
        let env = Envelope(formatVersion: format, appVersion: VIGBTVersion.string, savedAt: Date(), payload: value)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(env)
    }

    /// Reads a versioned file, or a legacy (format 1) file that is just the bare payload.
    public static func decode<T: Codable>(_ type: T.Type, from data: Data, supported: Int) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let header = try? dec.decode(Header.self, from: data) {
            guard header.formatVersion <= supported else {
                throw DecodeError.newerFormat(found: header.formatVersion, supported: supported)
            }
            if let env = try? dec.decode(Envelope<T>.self, from: data) { return env.payload }
            throw DecodeError.unreadable
        }
        // Format 1: written before versioning existed, with the default (deferred) date strategy.
        if let legacy = try? JSONDecoder().decode(T.self, from: data) { return legacy }
        throw DecodeError.unreadable
    }
}
