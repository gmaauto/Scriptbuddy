import Foundation

/// A specific club in the bag (Phase 5.3). Each maps to a spin category (`Club`) for ballistics.
public enum BagClub: String, Codable, CaseIterable, Identifiable, Sendable {
    case driver, wood3, wood5, wood7
    case hybrid2, hybrid3, hybrid4, hybrid5
    case iron3, iron4, iron5, iron6, iron7, iron8, iron9
    case pitchingWedge, gapWedge, sandWedge, lobWedge

    public var id: String { rawValue }

    /// Spoken and displayed name, e.g. "7-iron".
    public var name: String {
        switch self {
        case .driver: return "Driver"
        case .wood3: return "3-wood"
        case .wood5: return "5-wood"
        case .wood7: return "7-wood"
        case .hybrid2: return "2-hybrid"
        case .hybrid3: return "3-hybrid"
        case .hybrid4: return "4-hybrid"
        case .hybrid5: return "5-hybrid"
        case .iron3: return "3-iron"
        case .iron4: return "4-iron"
        case .iron5: return "5-iron"
        case .iron6: return "6-iron"
        case .iron7: return "7-iron"
        case .iron8: return "8-iron"
        case .iron9: return "9-iron"
        case .pitchingWedge: return "Pitching wedge"
        case .gapWedge: return "Gap wedge"
        case .sandWedge: return "Sand wedge"
        case .lobWedge: return "Lob wedge"
        }
    }

    public var spinCategory: Club {
        switch self {
        case .driver: return .driver
        case .wood3, .wood5, .wood7: return .fairwayWood
        case .hybrid2, .hybrid3, .hybrid4, .hybrid5: return .hybrid
        case .iron3, .iron4, .iron5: return .longIron
        case .iron6, .iron7: return .midIron
        case .iron8, .iron9: return .shortIron
        case .pitchingWedge, .gapWedge, .sandWedge, .lobWedge: return .wedge
        }
    }

    /// Starting carry before any shots are learned (typical mid-handicap golfer). Editable by the golfer.
    public var defaultCarryYards: Double {
        switch self {
        case .driver: return 220
        case .wood3: return 200
        case .wood5: return 185
        case .wood7: return 175
        case .hybrid2: return 190
        case .hybrid3: return 180
        case .hybrid4: return 170
        case .hybrid5: return 160
        case .iron3: return 175
        case .iron4: return 165
        case .iron5: return 158
        case .iron6: return 150
        case .iron7: return 140
        case .iron8: return 130
        case .iron9: return 120
        case .pitchingWedge: return 110
        case .gapWedge: return 98
        case .sandWedge: return 85
        case .lobWedge: return 70
        }
    }

    static let standardBag: Set<BagClub> = [.driver, .wood3, .wood5, .hybrid4, .iron5, .iron6, .iron7, .iron8,
                                             .iron9, .pitchingWedge, .gapWedge, .sandWedge, .lobWedge]
}

public struct ClubStats: Codable, Equatable, Identifiable, Sendable {
    public var club: BagClub
    public var isInBag: Bool
    /// Carry entered by the golfer; overrides everything else.
    public var userCarryMeters: Double?
    /// Rolling median of the golfer's recent tracked carries with this club.
    public var learnedCarryMeters: Double?
    public var sampleCount: Int

    public var id: String { club.rawValue }

    /// Learned carries are used once at least this many shots have been tracked.
    public static let minimumSamples = 3

    public var effectiveCarryMeters: Double {
        if let u = userCarryMeters { return u }
        if let l = learnedCarryMeters, sampleCount >= Self.minimumSamples { return l }
        return Units.meters(fromYards: club.defaultCarryYards)
    }

    public var isLearned: Bool { userCarryMeters == nil && learnedCarryMeters != nil && sampleCount >= Self.minimumSamples }
}

public struct ClubBag: Codable, Equatable, Sendable {
    public var stats: [ClubStats]

    public init(stats: [ClubStats]) {
        self.stats = stats
    }

    public static var standard: ClubBag {
        ClubBag(stats: BagClub.allCases.map {
            ClubStats(club: $0, isInBag: BagClub.standardBag.contains($0), sampleCount: 0)
        })
    }

    /// Clubs in the bag, longest carry first.
    public var playable: [ClubStats] {
        stats.filter(\.isInBag).sorted { $0.effectiveCarryMeters > $1.effectiveCarryMeters }
    }

    public subscript(club: BagClub) -> ClubStats? {
        stats.first { $0.club == club }
    }

    public mutating func update(_ club: BagClub, _ change: (inout ClubStats) -> Void) {
        if let i = stats.firstIndex(where: { $0.club == club }) { change(&stats[i]) }
    }

    /// Re-learns each club's carry from the last `window` real (non-simulated) tracked shots.
    public mutating func learn(from shots: [ShotRecord], window: Int = 10) {
        for i in stats.indices {
            let carries = shots
                .filter { $0.bagClub == stats[i].club && $0.isSimulated != true }
                .sorted { $0.capturedAt > $1.capturedAt }
                .compactMap { $0.trajectory?.carryMeters }
                .prefix(window)
            stats[i].sampleCount = carries.count
            stats[i].learnedCarryMeters = carries.isEmpty ? nil : Self.median(Array(carries))
        }
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }
}

public struct ClubRecommendation: Equatable, Sendable {
    public enum Reason: String, Sendable {
        /// Smallest club that reaches the plays-like distance.
        case reaches
        /// Target is beyond every club; this is the longest club that avoids hazards across the line.
        case layUp
        /// Target is beyond every club and no hazard is in play: hit the longest club.
        case longest
        /// Target is shorter than the shortest club: a partial swing with it.
        case partialShot
    }

    public var distanceToPinMeters: Double
    public var playsLikeMeters: Double
    public var recommended: BagClub
    public var recommendedCarryMeters: Double
    public var alternatives: [BagClub]
    public var reason: Reason
    /// Hazard that forced a lay-up, if any.
    public var layUpHazard: HazardSpan?

    /// Spoken/displayed recommendation.
    public var readout: String {
        let pin = Readout.whole(Units.yards(fromMeters: distanceToPinMeters))
        let plays = Readout.whole(Units.yards(fromMeters: playsLikeMeters))
        let carry = Readout.whole(Units.yards(fromMeters: recommendedCarryMeters))
        var text = "\(pin) yards to the pin."
        if abs(playsLikeMeters - distanceToPinMeters) >= Units.meters(fromYards: 2) { text += " Plays \(plays)." }
        switch reason {
        case .reaches:
            text += " Recommended: \(recommended.name). Your \(recommended.name) carries \(carry)."
        case .layUp:
            let hazard = layUpHazard.map { " It stays short of the \($0.kind.spokenName.lowercased()) at \(Readout.whole(Units.yards(fromMeters: $0.start))) yards." } ?? ""
            text += " Lay up with \(recommended.name), which carries \(carry).\(hazard)"
        case .longest:
            text += " Out of range. Hit your \(recommended.name), which carries \(carry)."
        case .partialShot:
            text += " Partial swing with your \(recommended.name)."
        }
        return text
    }
}

/// Phase 5.3: recommends a club from the distance to the pin and the golfer's own carries.
public enum ClubAdvisor {
    /// Short-side margin: a club may be up to this much short of the plays-like distance.
    public static let shortSideMarginMeters = Units.meters(fromYards: 5)
    /// Lay-ups must land at least this far short of (or past) a hazard crossing the line.
    public static let layUpMarginMeters = Units.meters(fromYards: 10)

    /// Plays-like distance: +1 yard per metre of rise (spec §5.3) and ±1% / 0.5% per mph of head / tail wind.
    public static func playsLike(distanceMeters d: Double, elevationChangeMeters: Double? = nil,
                                 headwindMph: Double? = nil) -> Double {
        var out = d + (elevationChangeMeters ?? 0) * Units.metersPerYard
        if let w = headwindMph {
            out *= w >= 0 ? 1 + 0.01 * w : 1 + 0.005 * w
        }
        return max(0, out)
    }

    /// - Parameter hazards: spans measured from the golfer's position along the playing line.
    public static func recommend(distanceToPinMeters d: Double, bag: ClubBag, elevationChangeMeters: Double? = nil,
                                 headwindMph: Double? = nil, hazards: [HazardSpan] = []) -> ClubRecommendation? {
        let clubs = bag.playable
        guard let longest = clubs.first, let shortest = clubs.last else { return nil }
        let target = playsLike(distanceMeters: d, elevationChangeMeters: elevationChangeMeters, headwindMph: headwindMph)

        func make(_ s: ClubStats, _ reason: ClubRecommendation.Reason, hazard: HazardSpan? = nil) -> ClubRecommendation {
            let i = clubs.firstIndex(of: s) ?? 0
            var alts: [BagClub] = []
            if i > 0 { alts.append(clubs[i - 1].club) }               // one club longer
            if i + 1 < clubs.count { alts.append(clubs[i + 1].club) } // one club shorter
            return ClubRecommendation(distanceToPinMeters: d, playsLikeMeters: target, recommended: s.club,
                                      recommendedCarryMeters: s.effectiveCarryMeters, alternatives: alts,
                                      reason: reason, layUpHazard: hazard)
        }

        if target <= shortest.effectiveCarryMeters - shortSideMarginMeters {
            return make(shortest, .partialShot)
        }
        // Smallest club that reaches (within the short-side margin).
        if let reach = clubs.last(where: { $0.effectiveCarryMeters >= target - shortSideMarginMeters }) {
            return make(reach, .reaches)
        }
        // Out of range: longest club whose landing point keeps clear of hazards across the line.
        let crossing = hazards.filter { $0.side == .crossing && $0.end > 0 }
        guard !crossing.isEmpty else { return make(longest, .longest) }
        for s in clubs {
            let landing = s.effectiveCarryMeters
            let blocking = crossing.first {
                landing > $0.start - layUpMarginMeters && landing < $0.end + layUpMarginMeters
            }
            if blocking == nil {
                let reason: ClubRecommendation.Reason = s == longest ? .longest : .layUp
                let hazard = crossing.first { $0.start - layUpMarginMeters >= landing }
                return make(s, reason, hazard: reason == .layUp ? hazard : nil)
            }
        }
        return make(shortest, .layUp, hazard: crossing.first)
    }
}
