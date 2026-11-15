import Foundation
import VIGBTCore

/// Local persistence: shot history, free-tier quota, onboarding acknowledgment and colour profile.
/// Everything stays on the device (no network, no account).
@MainActor
final class ShotStore {
    static let maxShots = 30

    static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VIGBT", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated static var clipsDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VIGBT/Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private(set) var shots: [ShotRecord] = []
    private(set) var quota = ShotQuota()
    private let defaults = UserDefaults.standard

    /// Files written by a newer app version: kept untouched, never overwritten (SPEC §10).
    private(set) var lockedFiles: Set<String> = []

    init() {
        shots = load([ShotRecord].self, "shots.json", format: DataFormat.shots) ?? []
        quota = load(ShotQuota.self, "quota.json", format: DataFormat.quota) ?? ShotQuota()
    }

    var theme: Theme {
        get { defaults.string(forKey: "theme").flatMap(Theme.init(rawValue:)) ?? .highContrastDark }
        set { defaults.set(newValue.rawValue, forKey: "theme") }
    }

    var ballHighlightEnabled: Bool {
        get { defaults.object(forKey: "ballHighlight") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ballHighlight") }
    }

    var hasAcceptedDisclaimer: Bool {
        get { defaults.bool(forKey: "acceptedDisclaimerV1") }
        set { defaults.set(newValue, forKey: "acceptedDisclaimerV1") }
    }

    var colorProfile: BallColorProfile {
        get {
            guard let data = defaults.data(forKey: "colorProfile"),
                  let p = try? JSONDecoder().decode(BallColorProfile.self, from: data) else { return .neonPink } // recommended colour (SPEC Phase 4.5)
            return p
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "colorProfile") }
    }

    /// Last wind the golfer entered (ignored once stale, see `WindInput.maxAge`).
    var wind: WindInput? {
        get { defaults.data(forKey: "wind").flatMap { try? JSONDecoder().decode(WindInput.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "wind") }
    }

    var club: Club {
        get { defaults.string(forKey: "club").flatMap(Club.init(rawValue:)) ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "club") }
    }

    func recordShotTaken(at date: Date = Date()) {
        quota.record(at: date)
        save(quota, "quota.json", format: DataFormat.quota)
    }

    func add(_ shot: ShotRecord) {
        shots.insert(shot, at: 0)
        while shots.count > Self.maxShots {
            let old = shots.removeLast()
            if let name = old.clipFileName {
                try? FileManager.default.removeItem(at: Self.clipsDirectory.appendingPathComponent(name))
            }
        }
        save(shots, "shots.json", format: DataFormat.shots)
    }

    func update(_ shot: ShotRecord) {
        guard let i = shots.firstIndex(where: { $0.id == shot.id }) else { return }
        shots[i] = shot
        save(shots, "shots.json", format: DataFormat.shots)
    }

    func clipURL(for shot: ShotRecord) -> URL? {
        guard let name = shot.clipFileName else { return nil }
        let url = Self.clipsDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func load<T: Codable>(_ type: T.Type, _ name: String, format: Int) -> T? {
        guard let data = try? Data(contentsOf: Self.supportDirectory.appendingPathComponent(name)) else { return nil }
        do {
            return try DataFormat.decode(T.self, from: data, supported: format)
        } catch DataFormat.DecodeError.newerFormat {
            lockedFiles.insert(name)
            return nil
        } catch {
            return nil
        }
    }

    private func save<T: Codable>(_ value: T, _ name: String, format: Int) {
        guard !lockedFiles.contains(name), let data = try? DataFormat.encode(value, format: format) else { return }
        try? data.write(to: Self.supportDirectory.appendingPathComponent(name), options: .atomic)
    }
}
