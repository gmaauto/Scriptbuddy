import Foundation

/// StoreKit 2 product identifiers (Section 2.1).
public enum ProductID {
    public static let proLifetimeUnlock = "com.vigbt.pro.unlock"
}

public enum EntitlementTier: String, Codable, Sendable {
    case free
    case pro
}

public enum Feature: String, Codable, CaseIterable, Sendable {
    case swingCapture
    case slowMotionReplay
    case unlimitedShots
    case ballisticEstimation
    case walkToBallNavigation
    case hapticHoming
}

/// Pure gating logic. The iOS layer derives `tier` from `Transaction.currentEntitlements`
/// (verified on-device by StoreKit 2's JWS signature check) and persists `ShotQuota` locally.
public struct EntitlementGate: Sendable {
    public static let freeShotsPerDay = 3

    public var tier: EntitlementTier

    public init(tier: EntitlementTier) {
        self.tier = tier
    }

    public func isEnabled(_ feature: Feature) -> Bool {
        switch feature {
        case .swingCapture, .slowMotionReplay:
            return true
        case .unlimitedShots, .ballisticEstimation, .walkToBallNavigation, .hapticHoming:
            return tier == .pro
        }
    }

    public func canCaptureShot(quota: ShotQuota, now: Date, calendar: Calendar = .current) -> Bool {
        tier == .pro || quota.shots(on: now, calendar: calendar) < Self.freeShotsPerDay
    }
}

/// Free-tier daily shot counter, keyed by local calendar day.
public struct ShotQuota: Codable, Equatable, Sendable {
    public private(set) var day: Date?
    public private(set) var count: Int = 0

    public init() {}

    public func shots(on date: Date, calendar: Calendar = .current) -> Int {
        guard let day, calendar.isDate(day, inSameDayAs: date) else { return 0 }
        return count
    }

    public mutating func record(at date: Date, calendar: Calendar = .current) {
        if let day, calendar.isDate(day, inSameDayAs: date) {
            count += 1
        } else {
            day = calendar.startOfDay(for: date)
            count = 1
        }
    }
}
