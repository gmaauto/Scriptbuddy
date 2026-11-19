import XCTest
@testable import VIGBTCore

/// Synthetic swings: hand height (torso lengths above the hips) over time, rendered as body poses.
struct SyntheticSwing {
    var addressSeconds = 1.5
    var addressHeight = -0.45
    var backswingSeconds = 0.9
    var tempo = 3.0
    var topHeight = 1.3
    var followHeight = 1.1
    var start = 100.0

    var takeaway: Double { start + addressSeconds }
    var top: Double { takeaway + backswingSeconds }
    var impact: Double { top + backswingSeconds / tempo }
    var end: Double { impact + 0.6 }

    func height(at t: Double) -> Double {
        if t < takeaway { return addressHeight }
        if t < top { // slow start, smooth top
            let s = (t - takeaway) / backswingSeconds
            return addressHeight + (topHeight - addressHeight) * (1 - cos(.pi * s)) / 2
        }
        if t < impact { // accelerating down to the ball
            let s = (t - top) / (impact - top)
            return topHeight - (topHeight - addressHeight) * s * s
        }
        let s = min(1, (t - impact) / 0.5)
        return addressHeight + (followHeight - addressHeight) * sin(.pi / 2 * s)
    }

    static func pose(time: Double, height h: Double, noise: Double = 0, rng: inout SeededRandom,
                     visible: Bool = true) -> BodyPose {
        let torso = 0.2, hipY = 0.6
        func n() -> Double { noise == 0 ? 0 : Double.random(in: -noise...noise, using: &rng) }
        var j: [BodyPose.Joint: BodyPose.Point] = [
            .leftHip: .init(x: 0.45, y: hipY), .rightHip: .init(x: 0.55, y: hipY),
            .leftShoulder: .init(x: 0.42, y: hipY - torso), .rightShoulder: .init(x: 0.58, y: hipY - torso),
            .leftWrist: .init(x: 0.5, y: hipY - (h + n()) * torso), .rightWrist: .init(x: 0.5, y: hipY - (h + n()) * torso),
            .nose: .init(x: 0.5, y: hipY - torso * 1.4),
            .leftAnkle: .init(x: 0.44, y: 0.92), .rightAnkle: .init(x: 0.56, y: 0.92),
        ]
        if !visible { j = j.mapValues { BodyPose.Point(x: $0.x, y: $0.y, confidence: 0.1) } }
        return BodyPose(time: time, joints: j)
    }

    /// Runs the tracker over the swing at `fps`, returning the tracker and all events.
    func track(fps: Double = 30, noise: Double = 0.02, seed: UInt64 = 1) -> (SwingTracker, [SwingTracker.Event]) {
        var rng = SeededRandom(seed: seed)
        var tracker = SwingTracker()
        var events: [SwingTracker.Event] = []
        var t = start + Double.random(in: 0..<(1 / fps), using: &rng)
        while t < end {
            events += tracker.ingest(Self.pose(time: t, height: height(at: t), noise: noise, rng: &rng))
            t += 1 / fps
        }
        return (tracker, events)
    }
}

final class SwingTrackerTests: XCTestCase {
    func testDetectsSwingAndMeasuresTempo() throws {
        let swing = SyntheticSwing()
        let (tracker, events) = swing.track()
        XCTAssertEqual(events.first, .addressSet)
        let impact = try XCTUnwrap(events.compactMap { if case .impactZone(let t) = $0 { return t } else { return nil } }.first)
        XCTAssertEqual(impact, swing.impact, accuracy: 0.04, "hands reach the ball within a frame of true impact")
        let s = try XCTUnwrap(tracker.lastSwing)
        XCTAssertLessThan(s.takeawayTime, s.topTime)
        XCTAssertLessThan(s.topTime, s.impactTime)
        XCTAssertGreaterThan(s.tempo, 1.5, "camera tempo reads low but stays in a plausible range")
    }

    func testTempoCoachComparesWithUsual() {
        var c = TempoCoach()
        XCTAssertEqual(c.record(2.2), .learning)
        XCTAssertEqual(c.record(2.25), .learning)
        XCTAssertEqual(c.record(2.15), .learning)
        XCTAssertEqual(c.record(2.2), .steady)
        XCTAssertEqual(c.record(1.8), .quicker)
        XCTAssertEqual(c.record(2.7), .slower)
        XCTAssertEqual(Readout.tempo(.learning), nil)
        XCTAssertEqual(Readout.tempo(.quicker), "Tempo quicker than your usual.")
    }

    func testWaggleIsNotASwing() {
        var rng = SeededRandom(seed: 3)
        var tracker = SwingTracker()
        var events: [SwingTracker.Event] = []
        for k in 0..<120 {
            let t = Double(k) / 30
            let h = -0.45 + (t > 1.5 && t < 2.3 ? 0.5 * sin(.pi * (t - 1.5) / 0.8) : 0) // half-height waggle
            events += tracker.ingest(SyntheticSwing.pose(time: t, height: h, rng: &rng))
        }
        XCTAssertFalse(events.contains { if case .swingCompleted = $0 { return true } else { return false } })
        XCTAssertTrue(tracker.recentImpacts.isEmpty)
    }

    func testGateAcceptsOwnSwingRejectsNeighbourWhileStill() {
        let swing = SyntheticSwing()
        let (tracker, _) = swing.track()
        let gate = StrikeGate()
        XCTAssertEqual(gate.decide(impactTime: swing.impact + 0.009, tracker: tracker), .accept(.swingMatched))
        // A strike sound while the golfer stood still at address, before the takeaway.
        XCTAssertEqual(gate.decide(impactTime: swing.takeaway - 0.4, tracker: tracker), .reject)
        XCTAssertEqual(gate.decide(impactTime: swing.takeaway - 0.4, tracker: tracker, manual: true), .accept(.manual))
    }

    func testGateAcceptsWhenGolferNotVisible() {
        var rng = SeededRandom(seed: 4)
        var tracker = SwingTracker()
        for k in 0..<90 {
            _ = tracker.ingest(SyntheticSwing.pose(time: Double(k) / 30, height: -0.45, rng: &rng, visible: false))
        }
        XCTAssertEqual(StrikeGate().decide(impactTime: 2.0, tracker: tracker), .accept(.golferNotVisible))
        // No pose frames at all (pose service off or too slow): never reject.
        XCTAssertEqual(StrikeGate().decide(impactTime: 2.0, tracker: SwingTracker()), .accept(.golferNotVisible))
    }

    func testViewClassification() {
        var rng = SeededRandom(seed: 5)
        let faceOn = SyntheticSwing.pose(time: 0, height: -0.45, rng: &rng)
        XCTAssertEqual(faceOn.view, .faceOn)
        var dtl = faceOn
        dtl.joints[.leftShoulder]?.x = 0.49
        dtl.joints[.rightShoulder]?.x = 0.51
        XCTAssertEqual(dtl.view, .downTheLine)
        XCTAssertTrue(faceOn.isFullBody)
    }

    /// Simulation (SPEC §9.5): 2,000 random swings at 30 and 15 pose frames per second, with pose noise.
    /// A real strike must never be rejected; a neighbour's strike while the golfer is still should be.
    func testSimulatedSwingsNeverLoseARealShot() {
        var rng = SeededRandom(seed: 2026)
        var detected = 0, falseRejects = 0, neighbourRejected = 0, impactErrors: [Double] = []
        let n = 2000
        for i in 0..<n {
            var s = SyntheticSwing()
            s.addressSeconds = Double.random(in: 1.0...3.0, using: &rng)
            s.addressHeight = Double.random(in: -0.6 ... -0.3, using: &rng)
            s.backswingSeconds = Double.random(in: 0.65...1.2, using: &rng)
            s.tempo = Double.random(in: 2.0...4.0, using: &rng)
            s.topHeight = Double.random(in: 0.9...1.6, using: &rng)
            s.followHeight = Double.random(in: 0.7...1.4, using: &rng)
            let fps = i % 2 == 0 ? 30.0 : 15.0
            let (tracker, events) = s.track(fps: fps, noise: 0.03, seed: UInt64(i + 10))
            let sound = s.impact + 0.009 + Double.random(in: -0.02...0.02, using: &rng) // acoustic delay + jitter
            if !StrikeGate().decide(impactTime: sound, tracker: tracker).isAccepted { falseRejects += 1 }
            if StrikeGate().decide(impactTime: s.takeaway - 0.5, tracker: tracker) == .reject { neighbourRejected += 1 }
            if tracker.lastSwing != nil { detected += 1 }
            if let ti = events.compactMap({ if case .impactZone(let t) = $0 { return t } else { return nil } }).first {
                impactErrors.append(abs(ti - s.impact))
            }
        }
        impactErrors.sort()
        let impactP99 = impactErrors[Int(Double(impactErrors.count) * 0.99)]
        print("SwingTracker simulation: \(n) swings, detected \(detected), false rejects \(falseRejects), " +
              "neighbour strikes rejected \(neighbourRejected), impact timing p99 " + String(format: "%.0f ms", impactP99 * 1000))
        XCTAssertEqual(falseRejects, 0, "a real strike must never be thrown away")
        XCTAssertGreaterThan(Double(detected) / Double(n), 0.98)
        XCTAssertGreaterThan(Double(neighbourRejected) / Double(n), 0.9)
        XCTAssertLessThan(impactP99, StrikeGate().matchAfter, "impact timing well inside the gate window")
    }

    /// Tempo is used relative to the golfer's own swings, so what matters is repeatability and sensitivity.
    func testTempoFeedbackIsRepeatableAndSensitive() {
        func measured(_ tempo: Double, seed: UInt64, fps: Double) -> Double? {
            var s = SyntheticSwing()
            s.tempo = tempo
            return s.track(fps: fps, noise: 0.03, seed: seed).0.lastSwing?.tempo
        }
        var flaggedChange = 0, falseFlags = 0, trials = 0
        for k in 0..<300 {
            let fps = k % 2 == 0 ? 30.0 : 15.0
            var coach = TempoCoach()
            for j in 0..<5 { if let m = measured(3.0, seed: UInt64(k * 100 + j), fps: fps) { _ = coach.record(m) } }
            var steady = coach
            trials += 1
            if let m = measured(3.0, seed: UInt64(k * 100 + 50), fps: fps), steady.record(m) != .steady { falseFlags += 1 }
            if let m = measured(2.4, seed: UInt64(k * 100 + 60), fps: fps), coach.record(m) == .quicker { flaggedChange += 1 }
        }
        print("Tempo feedback: a 20% quicker swing flagged \(flaggedChange)/\(trials); same tempo flagged \(falseFlags)/\(trials)")
        XCTAssertGreaterThan(Double(flaggedChange) / Double(trials), 0.85)
        XCTAssertLessThan(Double(falseFlags) / Double(trials), 0.10)
    }
}
