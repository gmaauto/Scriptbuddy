import Foundation

// Swing detection from 2D body pose (SPEC §9.5, 0.15.0).
//
// Idea taken from the open-source Golf-swing-analyzer project (swing phases from wrist height relative to
// the hips); no code was copied. Our version is view-independent (works face-on and down the line), measures
// tempo, and decides whether a strike sound belongs to the golfer's own swing.

/// One frame of 2D body pose: normalized image coordinates, x to the right, y **down**, 0…1.
public struct BodyPose: Sendable, Equatable {
    public enum Joint: String, CaseIterable, Sendable {
        case nose, leftShoulder, rightShoulder, leftHip, rightHip, leftWrist, rightWrist, leftAnkle, rightAnkle
    }

    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var confidence: Double
        public init(x: Double, y: Double, confidence: Double = 1) {
            self.x = x
            self.y = y
            self.confidence = confidence
        }
    }

    /// Capture time on the host clock, seconds (the same clock as the strike's audio time).
    public var time: Double
    public var joints: [Joint: Point]

    public init(time: Double, joints: [Joint: Point]) {
        self.time = time
        self.joints = joints
    }

    public static let minConfidence = 0.3

    public func point(_ j: Joint) -> Point? {
        guard let p = joints[j], p.confidence >= Self.minConfidence else { return nil }
        return p
    }

    private func mid(_ a: Joint, _ b: Joint) -> (x: Double, y: Double)? {
        switch (point(a), point(b)) {
        case let (p?, q?): return ((p.x + q.x) / 2, (p.y + q.y) / 2)
        case let (p?, nil): return (p.x, p.y)
        case let (nil, q?): return (q.x, q.y)
        default: return nil
        }
    }

    /// Hands height above the hips, in torso lengths (positive = above the hips). Using torso lengths makes
    /// it independent of how far the golfer stands from the camera and of the camera angle.
    public var handHeight: Double? {
        guard let hip = mid(.leftHip, .rightHip), let shoulder = mid(.leftShoulder, .rightShoulder),
              let wrist = mid(.leftWrist, .rightWrist) else { return nil }
        let torso = ((shoulder.x - hip.x) * (shoulder.x - hip.x) + (shoulder.y - hip.y) * (shoulder.y - hip.y)).squareRoot()
        guard torso > 0.02 else { return nil }
        return (hip.y - wrist.y) / torso
    }

    /// Head, hips, hands and both ankles are all confidently visible.
    public var isFullBody: Bool {
        point(.nose) != nil && handHeight != nil && point(.leftAnkle) != nil && point(.rightAnkle) != nil
    }

    /// Face-on when the shoulders are spread across the image; down the line when they overlap.
    public var view: CameraView? {
        guard let l = point(.leftShoulder), let r = point(.rightShoulder), let hl = point(.leftHip),
              let hr = point(.rightHip) else { return nil }
        let width = abs(l.x - r.x)
        let torso = abs((l.y + r.y) / 2 - (hl.y + hr.y) / 2)
        guard torso > 0.02 else { return nil }
        return width / torso > 0.45 ? .faceOn : .downTheLine
    }

    public enum CameraView: String, Sendable { case faceOn, downTheLine }
}

/// A completed swing.
public struct Swing: Sendable, Equatable {
    /// Hands leave the address position, reach the top, and return to the ball.
    public var takeawayTime: Double
    public var topTime: Double
    public var impactTime: Double
    public var backswingSeconds: Double { topTime - takeawayTime }
    public var downswingSeconds: Double { impactTime - topTime }
    /// Backswing time divided by downswing time, as measured from 2D pose (see `TempoCoach`).
    public var tempo: Double { downswingSeconds > 0 ? backswingSeconds / downswingSeconds : 0 }
}

/// Follows swing phases frame by frame: address → backswing → top → downswing → impact → follow-through.
public struct SwingTracker: Sendable {
    public enum Phase: String, Sendable { case unknown, address, backswing, downswing, followThrough }

    public enum Event: Sendable, Equatable {
        /// The golfer has held still at address long enough to set the baseline.
        case addressSet
        /// Hands came back down to the ball: the moment of impact for a real swing.
        case impactZone(time: Double)
        /// Hands rose again after impact: the swing is complete.
        case swingCompleted(Swing)
    }

    // Thresholds in torso lengths and seconds. Chosen from typical swing kinematics; see SPEC §9.5.
    public var addressHoldSeconds = 0.6
    public var stillSpread = 0.15          // hands within this spread over the hold time count as still
    public var takeawayRise = 0.25         // rise above address that confirms the backswing has started
    public var takeawayStart = 0.05        // hands within this of address are still "at the ball"
    public var topMinRise = 0.9            // a real backswing lifts the hands at least this much
    public var topDrop = 0.15              // fall from the highest point that marks the top
    public var topBand = 0.3               // frames this close to the highest point time the top (most repeatable in §9.5)
    public var impactReach = 0.5           // the lowest point must come this close to the address height
    public var rebound = 0.1               // rise after the lowest point that confirms it was the bottom
    public var followRise = 0.5            // rise after impact that confirms the follow-through
    public var maxBackswingSeconds = 2.5
    public var maxDownswingSeconds = 0.8
    public var maxFollowSeconds = 1.2
    /// Seconds of history kept for `StrikeGate`.
    public var historySeconds = 4.0

    public private(set) var phase: Phase = .unknown
    /// Hand height at address (torso lengths), once set.
    public private(set) var addressHeight: Double?
    public private(set) var lastSwing: Swing?
    /// Recent frames: time, hand height (nil = not measurable), full body visible.
    public private(set) var history: [(time: Double, height: Double?, fullBody: Bool)] = []
    /// Impact-zone times of recent swings (kept for `historySeconds`).
    public private(set) var recentImpacts: [Double] = []

    private var stillSamples: [(time: Double, height: Double)] = []
    private var window: [(time: Double, height: Double)] = []
    private var takeawayTime: Double?
    private var lastAtBall: Double?
    private var low: [(time: Double, height: Double)] = []
    private var rise: [(time: Double, height: Double)] = []
    private var topFrames: [(time: Double, height: Double)] = []
    private var top: (time: Double, height: Double)?
    private var impact: Double?
    private var last: (time: Double, height: Double)?

    public init() {}

    public mutating func reset() { self = SwingTracker() }

    /// Feeds one frame; returns the events it produced.
    public mutating func ingest(_ pose: BodyPose) -> [Event] {
        history.append((pose.time, pose.handHeight, pose.isFullBody))
        history.removeAll { $0.time < pose.time - historySeconds }
        recentImpacts.removeAll { $0 < pose.time - historySeconds }
        guard let h = pose.handHeight else { return [] }
        let t = pose.time
        defer { last = (t, h) }
        // Stillness uses a 3-frame median, which removes single-frame pose jitter. Motion uses raw frames,
        // because the hands pass the ball too quickly for a filter.
        window.append((t, h))
        if window.count > 3 { window.removeFirst() }
        var events: [Event] = []

        switch phase {
        case .unknown, .address:
            if window.count == 3 {
                let mt = window[1].time, mh = window.map(\.height).sorted()[1]
                stillSamples.append((mt, mh))
                stillSamples.removeAll { $0.time < mt - addressHoldSeconds }
                let hs = stillSamples.map(\.height)
                if let lo = hs.min(), let hi = hs.max(), hi - lo <= stillSpread,
                   let first = stillSamples.first, mt - first.time >= addressHoldSeconds * 0.9 {
                    if phase == .unknown { events.append(.addressSet) }
                    addressHeight = hs.sorted()[hs.count / 2]
                    phase = .address
                }
                if phase == .address, let base = addressHeight, mh - base <= takeawayStart { lastAtBall = mt }
            }
            if phase == .address, let base = addressHeight, h - base > takeawayRise {
                // The swing started when the hands last sat at the ball, not when they crossed the threshold.
                takeawayTime = lastAtBall ?? crossing(from: last, to: (t, h), level: base + takeawayRise) ?? t
                top = (t, h)
                phase = .backswing
                stillSamples = []
            }
        case .backswing:
            guard let base = addressHeight, let start = takeawayTime else { return restart() }
            if h > (top?.height ?? -.infinity) { top = (t, h) }
            rise.append((t, h))
            if t - start > maxBackswingSeconds { return restart() }
            if let tp = top, tp.height - base >= topMinRise, tp.height - h >= topDrop {
                phase = .downswing
                low = [(t, h)]
                topFrames = rise.filter { $0.height >= tp.height - topBand }
            } else if h - base < takeawayRise / 2, (top?.height ?? h) - base < topMinRise {
                // Hands dropped back without a full backswing: a waggle, not a swing.
                phase = .address
                takeawayTime = nil
                lastAtBall = nil
                top = nil
            }
        case .downswing:
            guard let base = addressHeight, let tp = top else { return restart() }
            if t - tp.time > maxDownswingSeconds { return restart() }
            low.append((t, h))
            if h >= tp.height - topBand { topFrames.append((t, h)) }
            // Impact = lowest hand point after the top, once the hands start rising again.
            guard let iMin = low.indices.min(by: { low[$0].height < low[$1].height }) else { break }
            let m = low[iMin]
            if m.height - base <= impactReach, h - m.height >= rebound, iMin < low.count - 1 {
                let ti = iMin > 0 ? vertex(low[iMin - 1], m, low[iMin + 1]) : m.time
                // Top of the swing = vertex of a parabola fitted to every frame near the highest point.
                // A single highest frame is dominated by pose noise, because the top is flat.
                if let fitted = Self.peakTime(topFrames) { top = (fitted, tp.height) }
                impact = ti
                recentImpacts.append(ti)
                events.append(.impactZone(time: ti))
                phase = .followThrough
            }
        case .followThrough:
            guard let base = addressHeight, let ti = impact, let tp = top, let ta = takeawayTime else { return restart() }
            if h - base >= followRise {
                let swing = Swing(takeawayTime: ta, topTime: tp.time, impactTime: ti)
                lastSwing = swing
                events.append(.swingCompleted(swing))
                finishSwing()
            } else if t - ti > maxFollowSeconds {
                finishSwing() // hands stayed low (e.g. a punch shot): impact is still recorded
            }
        }
        return events
    }

    /// After a swing the golfer must settle again before the next one; the baseline is kept for `StrikeGate`.
    private mutating func finishSwing() {
        phase = .unknown
        takeawayTime = nil
        lastAtBall = nil
        top = nil
        impact = nil
        low = []
        rise = []
        topFrames = []
        stillSamples = []
    }

    /// Least-squares parabola h = a t² + b t + c through the frames; returns the time of its maximum.
    static func peakTime(_ f: [(time: Double, height: Double)]) -> Double? {
        guard f.count >= 3, let t0 = f.first?.time else { return nil }
        var s = [Double](repeating: 0, count: 5), r = [Double](repeating: 0, count: 3)
        for p in f {
            let x = p.time - t0
            var xp = 1.0
            for k in 0..<5 { s[k] += xp; if k < 3 { r[k] += xp * p.height }; xp *= x }
        }
        // Normal equations [s4 s3 s2; s3 s2 s1; s2 s1 s0] [a b c] = [r2 r1 r0], solved by Cramer's rule.
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let m = [[s[4], s[3], s[2]], [s[3], s[2], s[1]], [s[2], s[1], s[0]]]
        let d = det(m)
        guard abs(d) > 1e-12 else { return nil }
        let a = det([[r[2], s[3], s[2]], [r[1], s[2], s[1]], [r[0], s[1], s[0]]]) / d
        let b = det([[s[4], r[2], s[2]], [s[3], r[1], s[1]], [s[2], r[0], s[0]]]) / d
        guard a < 0 else { return nil }
        let tv = t0 - b / (2 * a)
        guard let lo = f.map(\.time).min(), let hi = f.map(\.time).max(), tv >= lo, tv <= hi else { return nil }
        return tv
    }

    /// Time of the lowest point of the parabola through three frames (falls back to the middle frame).
    private func vertex(_ a: (time: Double, height: Double), _ b: (time: Double, height: Double),
                        _ c: (time: Double, height: Double)) -> Double {
        let d1 = b.time - a.time, d2 = c.time - b.time
        guard d1 > 0, d2 > 0 else { return b.time }
        let s1 = (b.height - a.height) / d1, s2 = (c.height - b.height) / d2
        let curvature = (s2 - s1) / ((d1 + d2) / 2)
        guard curvature > 0 else { return b.time }
        let tv = (a.time + b.time) / 2 - s1 / curvature
        return min(c.time, max(a.time, tv))
    }

    private mutating func restart() -> [Event] {
        phase = addressHeight == nil ? .unknown : .address
        takeawayTime = nil
        lastAtBall = nil
        top = nil
        impact = nil
        low = []
        rise = []
        topFrames = []
        stillSamples = []
        return []
    }

    /// Time at which the hand height crossed `level` between two frames (linear interpolation).
    private func crossing(from a: (time: Double, height: Double)?, to b: (time: Double, height: Double), level: Double) -> Double? {
        guard let a, a.height != b.height else { return nil }
        let f = (level - a.height) / (b.height - a.height)
        guard f >= 0, f <= 1 else { return nil }
        return a.time + f * (b.time - a.time)
    }
}

/// Decides whether a strike sound came from the golfer's own swing (SPEC §9.5). It errs heavily towards
/// accepting: a missed real shot loses the ball, while a stray capture only costs a re-arm.
public struct StrikeGate: Sendable {
    public enum Decision: Sendable, Equatable {
        case accept(Reason)
        /// The golfer was clearly visible and still at address: another player's strike.
        case reject

        public enum Reason: String, Sendable { case swingMatched, golferNotVisible, uncertain, manual }
        public var isAccepted: Bool { if case .accept = self { return true } else { return false } }
    }

    /// Accept when the hands reached the ball within this window around the sound.
    public var matchBefore = 0.35
    public var matchAfter = 0.30
    /// Rejection needs the golfer in full view for at least this share of frames around the sound...
    public var minVisibleShare = 0.9
    /// ...over this span, and at least this many frames (so a slow pose rate never rejects).
    public var lookBefore = 1.0
    public var lookAfter = 0.3
    public var minFrames = 12
    /// ...with the hands inside this band around the address height the whole time (torso lengths).
    public var stillBand = 0.3

    public init() {}

    public func decide(impactTime t: Double, tracker: SwingTracker, manual: Bool = false) -> Decision {
        if manual { return .accept(.manual) }
        if tracker.recentImpacts.contains(where: { $0 >= t - matchBefore && $0 <= t + matchAfter }) {
            return .accept(.swingMatched)
        }
        let frames = tracker.history.filter { $0.time >= t - lookBefore && $0.time <= t + lookAfter }
        guard frames.count >= minFrames else { return .accept(.golferNotVisible) }
        let visible = frames.filter { $0.fullBody && $0.height != nil }
        guard Double(visible.count) / Double(frames.count) >= minVisibleShare, let base = tracker.addressHeight else {
            return .accept(.golferNotVisible)
        }
        let still = visible.allSatisfy { abs(($0.height ?? base) - base) <= stillBand }
        return still ? .reject : .accept(.uncertain)
    }
}

/// Compares each swing's tempo with the golfer's own recent swings (SPEC §9.5). An absolute ratio is not
/// spoken: from 2D pose the exact start of the takeaway is invisible, so camera tempo reads lower than a
/// club sensor would. The comparison with the golfer's own swings is repeatable to about 3–7% on simulated
/// swings, so a 10% change is reported.
public struct TempoCoach: Codable, Sendable, Equatable {
    public enum Feedback: String, Sendable { case learning, steady, quicker, slower }

    public private(set) var recent: [Double] = []
    public var keep = 10
    public var minBaseline = 3
    public var threshold = 0.10

    public init() {}

    /// The golfer's usual tempo: median of recent swings.
    public var usual: Double? {
        guard recent.count >= minBaseline else { return nil }
        return recent.sorted()[recent.count / 2]
    }

    /// Feedback for this swing compared with the usual, then adds it to the history.
    public mutating func record(_ tempo: Double) -> Feedback {
        guard tempo > 0, tempo.isFinite else { return .learning }
        defer {
            recent.append(tempo)
            if recent.count > keep { recent.removeFirst(recent.count - keep) }
        }
        guard let u = usual else { return .learning }
        if tempo < u * (1 - threshold) { return .quicker }
        if tempo > u * (1 + threshold) { return .slower }
        return .steady
    }
}
