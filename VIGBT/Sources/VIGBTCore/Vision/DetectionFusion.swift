import Foundation

/// A ball found by a trained detector (Core ML), in source pixels.
public struct ModelDetection: Equatable, Sendable {
    public var centerX: Double
    public var centerY: Double
    public var radiusPixels: Double
    /// Model confidence 0…1.
    public var confidence: Double

    public init(centerX: Double, centerY: Double, radiusPixels: Double, confidence: Double) {
        self.centerX = centerX
        self.centerY = centerY
        self.radiusPixels = radiusPixels
        self.confidence = confidence
    }
}

/// Metadata shipped with a trained detector. `validatedRangeMeters` is filled in only from a field test
/// (SPEC §12.10). Until then the search pattern keeps the heuristic's range, so a model can only add
/// finds, never widen the lanes on an unproven claim.
public struct BallDetectorInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    /// Dataset licences the model was trained on; must all be open (`OpenDataLicence.allowed`).
    public var trainingDataLicences: [String]
    public var validatedRangeMeters: [String: Double]?

    public init(name: String, version: String, trainingDataLicences: [String], validatedRangeMeters: [String: Double]? = nil) {
        self.name = name
        self.version = version
        self.trainingDataLicences = trainingDataLicences
        self.validatedRangeMeters = validatedRangeMeters
    }

    /// True only if every training-data licence is an approved open licence (SPEC §8).
    public var isOpenData: Bool {
        !trainingDataLicences.isEmpty && trainingDataLicences.allSatisfy { OpenDataLicence.allowed.contains($0.uppercased()) }
    }
}

public enum OpenDataLicence {
    /// SPDX ids accepted for training data. Copyleft-share-alike data (e.g. ODbL, CC-BY-SA) is accepted
    /// for training only because the model weights are published under the same open terms.
    public static let allowed: Set<String> = ["CC0-1.0", "CC-BY-4.0", "CC-BY-SA-4.0", "MIT", "APACHE-2.0", "BSD-3-CLAUSE", "ODBL-1.0"]
}

/// Combines the hand-built detectors (colour mask or `WhiteBallDetector`) with a trained model.
///
/// - Both agree (centres within 1.5 radii): confidence 1 − (1 − h)(1 − m).
/// - Model alone: accepted from `modelOnlyThreshold` (it sees further and handles white balls).
/// - Heuristic alone: accepted as before, at its own confidence.
/// The highest combined confidence wins.
public struct DetectionFusion: Sendable {
    public var modelOnlyThreshold: Double = 0.6
    public var heuristicOnlyThreshold: Double = 0.3

    public init() {}

    public func fuse(heuristic: [DetectionCandidate], model: [ModelDetection]) -> DetectionCandidate? {
        var best: (DetectionCandidate, Double)?
        func consider(_ c: DetectionCandidate, _ score: Double) {
            if score > (best?.1 ?? -1) { best = (c, score) }
        }
        var usedModel = Set<Int>()
        for h in heuristic {
            let hc = min(1, max(0, h.colorMatchFraction))
            var matched: (Int, ModelDetection)?
            for (i, m) in model.enumerated() {
                let d = ((h.centerX - m.centerX) * (h.centerX - m.centerX) + (h.centerY - m.centerY) * (h.centerY - m.centerY)).squareRoot()
                if d <= 1.5 * max(h.radiusPixels, m.radiusPixels, 1), m.confidence > (matched?.1.confidence ?? -1) {
                    matched = (i, m)
                }
            }
            if let match = matched {
                let m = match.1
                usedModel.insert(match.0)
                var c = h
                c.colorMatchFraction = 1 - (1 - hc) * (1 - m.confidence)
                consider(c, c.colorMatchFraction)
            } else if hc >= heuristicOnlyThreshold {
                consider(h, hc)
            }
        }
        for (i, m) in model.enumerated() where !usedModel.contains(i) && m.confidence >= modelOnlyThreshold {
            consider(DetectionCandidate(centerX: m.centerX, centerY: m.centerY, width: 2 * m.radiusPixels,
                                        height: 2 * m.radiusPixels, colorMatchFraction: m.confidence), m.confidence)
        }
        return best?.0
    }
}

/// Detection range used for search-lane spacing (SPEC §12.7, §12.10).
public enum DetectionRange {
    public static func meters(preset: BallColorPreset, model: BallDetectorInfo?) -> Double {
        let heuristic = preset == .white ? 4.0 : 6.0
        guard let validated = model?.validatedRangeMeters?[preset == .white ? "white" : "colour"] else { return heuristic }
        return max(heuristic, validated)
    }
}
