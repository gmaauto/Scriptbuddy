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

    init() {
        shots = load([ShotRecord].self, "shots.json") ?? []
        quota = load(ShotQuota.self, "quota.json") ?? ShotQuota()
    }

    var hasAcceptedDisclaimer: Bool {
        get { defaults.bool(forKey: "acceptedDisclaimerV1") }
        set { defaults.set(newValue, forKey: "acceptedDisclaimerV1") }
    }

    var colorProfile: BallColorProfile {
        get {
            guard let data = defaults.data(forKey: "colorProfile"),
                  let p = try? JSONDecoder().decode(BallColorProfile.self, from: data) else { return .neonOrange }
            return p
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "colorProfile") }
    }

    var club: Club {
        get { defaults.string(forKey: "club").flatMap(Club.init(rawValue:)) ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "club") }
    }

    func recordShotTaken(at date: Date = Date()) {
        quota.record(at: date)
        save(quota, "quota.json")
    }

    func add(_ shot: ShotRecord) {
        shots.insert(shot, at: 0)
        while shots.count > Self.maxShots {
            let old = shots.removeLast()
            if let name = old.clipFileName {
                try? FileManager.default.removeItem(at: Self.clipsDirectory.appendingPathComponent(name))
            }
        }
        save(shots, "shots.json")
    }

    func clipURL(for shot: ShotRecord) -> URL? {
        guard let name = shot.clipFileName else { return nil }
        let url = Self.clipsDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: Self.supportDirectory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: Self.supportDirectory.appendingPathComponent(name), options: .atomic)
    }
}
