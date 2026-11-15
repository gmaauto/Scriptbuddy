import Foundation

/// Fusion score (Phase 1.3): Score = w1·Kinematics + w2·Circularity + w3·ColorMatch, each term in [0, 1].
public struct FusionScorer: Codable, Equatable, Sendable {
    public var kinematicsWeight: Double = 0.5
    public var circularityWeight: Double = 0.25
    public var colorWeight: Double = 0.25
    /// Circularity gate: candidates outside [minAspect, maxAspect] are rejected outright.
    public var minAspect: Double = 0.7
    public var maxAspect: Double = 1.3
    /// Std-dev (pixels) of the Gaussian kinematic residual around the constant-velocity prediction.
    public var kinematicSigmaPixels: Double = 25
    /// Minimum fused score for a candidate to be accepted as the ball.
    public var acceptanceThreshold: Double = 0.45

    public init() {}

    /// 1.0 for a perfect circle, falling linearly to 0 at the aspect gate edges; `nil` if gated out.
    public func circularity(of c: DetectionCandidate) -> Double? {
        let a = c.aspectRatio
        guard a.isFinite, a >= minAspect, a <= maxAspect else { return nil }
        let halfWidth = a >= 1 ? (maxAspect - 1) : (1 - minAspect)
        return halfWidth > 0 ? max(0, 1 - abs(a - 1) / halfWidth) : 1
    }

    /// Gaussian likelihood of the candidate given a predicted position. With no prediction
    /// (first frames of a track) returns a neutral 0.5 so colour and shape decide.
    public func kinematics(of c: DetectionCandidate, predicted: (x: Double, y: Double)?) -> Double {
        guard let p = predicted else { return 0.5 }
        let dx = c.centerX - p.x
        let dy = c.centerY - p.y
        let d2 = dx * dx + dy * dy
        return exp(-d2 / (2 * kinematicSigmaPixels * kinematicSigmaPixels))
    }

    /// Returns `nil` when the candidate fails the circularity gate.
    public func score(_ c: DetectionCandidate, predicted: (x: Double, y: Double)?) -> Double? {
        guard let circ = circularity(of: c) else { return nil }
        let kin = kinematics(of: c, predicted: predicted)
        let color = min(1, max(0, c.colorMatchFraction))
        let total = kinematicsWeight + circularityWeight + colorWeight
        guard total > 0 else { return 0 }
        return (kinematicsWeight * kin + circularityWeight * circ + colorWeight * color) / total
    }
}

/// Greedy frame-by-frame tracker that links the best-scoring candidate per frame using a
/// constant-velocity prediction from the two previous accepted centroids.
public struct BallTracker: Sendable {
    public var scorer: FusionScorer
    /// Stop after this many consecutive frames with no accepted candidate (ball left the frame).
    public var maxMissedFrames: Int

    public init(scorer: FusionScorer = FusionScorer(), maxMissedFrames: Int = 3) {
        self.scorer = scorer
        self.maxMissedFrames = maxMissedFrames
    }

    /// - Parameter frames: candidates for frames T0+1, T0+2, … (index 0 ↔ frame offset 1).
    public func track(frames: [[DetectionCandidate]]) -> [TrackedCentroid] {
        var track: [TrackedCentroid] = []
        var missed = 0
        for (i, candidates) in frames.enumerated() {
            let offset = i + 1
            let predicted = prediction(for: offset, from: track)
            var best: (DetectionCandidate, Double)?
            for c in candidates {
                guard let s = scorer.score(c, predicted: predicted) else { continue }
                if s >= scorer.acceptanceThreshold, s > (best?.1 ?? -1) {
                    best = (c, s)
                }
            }
            if let best {
                let c = best.0
                track.append(TrackedCentroid(frameOffset: offset, x: c.centerX, y: c.centerY,
                                             radiusPixels: c.radiusPixels, score: best.1))
                missed = 0
            } else if !track.isEmpty {
                missed += 1
                if missed >= maxMissedFrames { break }
            }
        }
        return track
    }

    func prediction(for offset: Int, from track: [TrackedCentroid]) -> (x: Double, y: Double)? {
        guard track.count >= 2 else { return nil }
        let a = track[track.count - 2]
        let b = track[track.count - 1]
        let span = Double(b.frameOffset - a.frameOffset)
        guard span > 0 else { return nil }
        let vx = (b.x - a.x) / span
        let vy = (b.y - a.y) / span
        let ahead = Double(offset - b.frameOffset)
        return (b.x + vx * ahead, b.y + vy * ahead)
    }
}
