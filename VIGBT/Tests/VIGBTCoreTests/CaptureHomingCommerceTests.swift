import XCTest
@testable import VIGBTCore

final class CaptureTests: XCTestCase {
    func testRingBufferEvictsOldest() {
        var rb = RingBuffer<Int>(capacity: 3)
        XCTAssertNil(rb.append(1))
        rb.append(2)
        rb.append(3)
        XCTAssertTrue(rb.isFull)
        XCTAssertEqual(rb.append(4), 1)
        XCTAssertEqual(rb.elements, [2, 3, 4])
        XCTAssertEqual(Array(rb), [2, 3, 4])
        rb.removeAll()
        XCTAssertEqual(rb.count, 0)
    }

    func testRawPreRollWouldNotFitInMemory() {
        let b = RingBufferBudget()
        XCTAssertEqual(b.frameCount, 600)
        XCTAssertGreaterThan(b.rawBytes, 1_800_000_000)
        XCTAssertLessThan(b.encodedBytes(), 50_000_000)
    }

    func testClipWindow() {
        let w = ClipWindow()
        XCTAssertEqual(w.range(impactTime: 10), 8.5...13.5)
        XCTAssertEqual(w.captureStopTime(impactTime: 10), 13.5)
    }

    func testImpactDetectorTriggersOnceOnTransient() {
        var d = ImpactDetector()
        var t = 0.0
        var triggers: [Double] = []
        func feed(_ db: Double, _ n: Int) {
            for _ in 0..<n {
                if d.process(peakDB: db, at: t) { triggers.append(t) }
                t += 0.005
            }
        }
        feed(-48, 200)   // ambient
        feed(-35, 60)    // swing whoosh: must not trigger
        feed(-6, 3)      // impact
        feed(-15, 20)    // ring-down / echo inside refractory window
        feed(-48, 100)
        XCTAssertEqual(triggers.count, 1)
    }

    func testImpactDetectorIgnoresQuietEnvironmentSpikesBelowAbsoluteFloor() {
        var d = ImpactDetector(initialNoiseFloorDB: -80)
        XCTAssertFalse(d.process(peakDB: -40, at: 0), "24 dB over a very quiet floor but still too soft to be a strike")
    }
}

final class HomingTests: XCTestCase {
    func testPeripheralThenTicksThenLock() {
        var h = HomingController(framesToLock: 3)
        let first = h.process(GroundDetection(offsetX: 0.8, offsetY: 0.3, distanceMeters: 4))
        XCTAssertEqual(first.first, .peripheralDetected)
        guard case let .tick(farInterval, _)? = first.last else { return XCTFail("expected tick") }

        let closer = h.process(GroundDetection(offsetX: 0.2, offsetY: 0, distanceMeters: 3))
        XCTAssertFalse(closer.contains(.peripheralDetected))
        guard case let .tick(nearInterval, _)? = closer.last else { return XCTFail("expected tick") }
        XCTAssertLessThan(nearInterval, farInterval, "ticks accelerate as the ball is centred")

        var events: [HomingEvent] = []
        for _ in 0..<3 { events += h.process(GroundDetection(offsetX: 0.02, offsetY: 0.01, distanceMeters: 1.5)) }
        XCTAssertEqual(events.last, .locked)
        XCTAssertTrue(h.isLocked)
        XCTAssertTrue(h.process(GroundDetection(offsetX: 0, offsetY: 0, distanceMeters: 1)).isEmpty)
    }

    func testNoLockWhenCentredButTooFar() {
        var h = HomingController(framesToLock: 2)
        for _ in 0..<5 { _ = h.process(GroundDetection(offsetX: 0, offsetY: 0, distanceMeters: 5)) }
        XCTAssertFalse(h.isLocked)
    }

    func testLostAfterMisses() {
        var h = HomingController(framesToLose: 2)
        _ = h.process(GroundDetection(offsetX: 0.5, offsetY: 0, distanceMeters: nil))
        XCTAssertEqual(h.process(nil), [])
        XCTAssertEqual(h.process(nil), [.lost])
        XCTAssertEqual(h.process(GroundDetection(offsetX: 0.5, offsetY: 0, distanceMeters: nil)).first, .peripheralDetected)
    }
}

final class CommerceTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testFreeTierFeatureGating() {
        let free = EntitlementGate(tier: .free)
        XCTAssertTrue(free.isEnabled(.swingCapture))
        XCTAssertTrue(free.isEnabled(.slowMotionReplay))
        XCTAssertFalse(free.isEnabled(.ballisticEstimation))
        XCTAssertFalse(free.isEnabled(.walkToBallNavigation))
        XCTAssertTrue(Feature.allCases.allSatisfy(EntitlementGate(tier: .pro).isEnabled))
    }

    func testFreeTierDailyLimitResetsNextDay() {
        let gate = EntitlementGate(tier: .free)
        var quota = ShotQuota()
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<3 {
            XCTAssertTrue(gate.canCaptureShot(quota: quota, now: day1, calendar: calendar))
            quota.record(at: day1, calendar: calendar)
        }
        XCTAssertFalse(gate.canCaptureShot(quota: quota, now: day1, calendar: calendar))
        XCTAssertTrue(EntitlementGate(tier: .pro).canCaptureShot(quota: quota, now: day1, calendar: calendar))
        let day2 = day1.addingTimeInterval(86_400)
        XCTAssertTrue(gate.canCaptureShot(quota: quota, now: day2, calendar: calendar))
        quota.record(at: day2, calendar: calendar)
        XCTAssertEqual(quota.shots(on: day2, calendar: calendar), 1)
    }
}
