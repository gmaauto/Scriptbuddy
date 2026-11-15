import Foundation
import Observation
import VIGBTCore

/// Phase 5: the current course, round, bag and live club recommendation.
@MainActor
@Observable
final class RoundModel {
    let courses = CourseService()
    private(set) var course: GolfCourse?
    private(set) var state: RoundState?
    private(set) var recommendation: ClubRecommendation?
    private(set) var distanceToPinMeters: Double?
    /// Set when GPS puts the golfer on the next hole's tee; the UI asks to confirm.
    private(set) var pendingHole: Int?
    var bag: ClubBag {
        didSet { saveBag() }
    }

    @ObservationIgnored var speak: (String) -> Void = { _ in }
    /// Called when the recommendation changes so the club picker can pre-select it.
    @ObservationIgnored var onRecommendedClub: (BagClub) -> Void = { _ in }
    @ObservationIgnored private var lastPosition: GeoCoordinate?
    @ObservationIgnored private var lastRecommended: BagClub?
    @ObservationIgnored private let defaults = UserDefaults.standard

    var isActive: Bool { course != nil && state != nil }
    var currentHole: Hole? { state.flatMap { course?.hole($0.currentHole) } }
    var teeSetName: String? { state?.teeSetName }

    init() {
        if let data = defaults.data(forKey: "clubBag"), let b = try? JSONDecoder().decode(ClubBag.self, from: data) {
            bag = b
        } else {
            bag = .standard
        }
        if let data = defaults.data(forKey: "round"), let r = try? JSONDecoder().decode(RoundState.self, from: data),
           let c = courses.saved.first(where: { $0.id == r.courseID }) {
            course = c
            state = r
        }
    }

    // MARK: Round lifecycle

    func start(course: GolfCourse, teeSet: String?, startingHole: Int) {
        self.course = course
        state = RoundState(courseID: course.id, teeSetName: teeSet, startingHole: startingHole)
        pendingHole = nil
        saveRound()
        announceHole()
    }

    func end() {
        course = nil
        state = nil
        recommendation = nil
        distanceToPinMeters = nil
        pendingHole = nil
        defaults.removeObject(forKey: "round")
    }

    func next() {
        guard let s = state, let c = course else { return }
        go(to: s.next(in: c.holeNumbers))
    }

    func previous() {
        guard let s = state, let c = course else { return }
        go(to: s.previous(in: c.holeNumbers))
    }

    func confirmPendingHole() {
        guard let h = pendingHole else { return }
        go(to: h)
    }

    func dismissPendingHole() {
        pendingHole = nil
    }

    private func go(to hole: Int) {
        guard var s = state else { return }
        s.advance(to: hole)
        state = s
        pendingHole = nil
        lastRecommended = nil
        saveRound()
        announceHole()
        if let p = lastPosition { update(position: p, force: true) }
        if let c = course, s.isComplete(holeCount: c.holes.count) {
            speak("That completes all \(c.holes.count) holes.")
        }
    }

    private func announceHole() {
        guard let hole = currentHole else { return }
        speak(HoleDescriber.describe(hole: hole, teeName: teeSetName, golfer: nil).summary)
    }

    func record(shot: ShotRecord) {
        guard state != nil else { return }
        state?.record(shot: shot.id)
        saveRound()
    }

    func learn(from shots: [ShotRecord]) {
        bag.learn(from: shots)
    }

    // MARK: Live updates (called on every location fix)

    func update(position: GeoCoordinate, force: Bool = false) {
        if !force, let last = lastPosition, GeoMath.distance(from: last, to: position) < 3 { return }
        lastPosition = position
        guard let c = course, let s = state, let hole = currentHole else { return }

        // Arrived on the next hole's tee? Ask before switching.
        let upcoming = s.next(in: c.holeNumbers)
        if pendingHole == nil,
           CourseLocator.holeOnTee(course: c, position: position, expected: upcoming) == upcoming,
           upcoming != s.currentHole {
            pendingHole = upcoming
            speak("Hole \(upcoming). Are you on the tee?")
        }

        guard let d = CourseLocator.distanceToPin(hole: hole, from: position) else {
            recommendation = nil
            distanceToPinMeters = nil
            return
        }
        distanceToPinMeters = d
        let elevation: Double? = nil // Copernicus/SRTM elevation not bundled yet (spec §8: optional).
        recommendation = ClubAdvisor.recommend(distanceToPinMeters: d, bag: bag, elevationChangeMeters: elevation,
                                               hazards: CourseLocator.hazards(hole: hole, from: position))
        if let r = recommendation, r.recommended != lastRecommended {
            lastRecommended = r.recommended
            onRecommendedClub(r.recommended)
        }
    }

    func announceRecommendation() {
        if let r = recommendation {
            speak(r.readout)
        } else if currentHole?.target == nil {
            speak("The green for this hole has not been mapped. Stand by the hole and press Set pin here.")
        } else {
            speak("Waiting for your position.")
        }
    }

    func describeHole(golfer: GeoCoordinate?) -> HoleDescription? {
        currentHole.map { HoleDescriber.describe(hole: $0, teeName: teeSetName, golfer: golfer) }
    }

    // MARK: On-site marking (works for any course source)

    func markTee(at p: GeoCoordinate) {
        mutateCourse { c, n in c.markTee(hole: n, at: p, name: teeSetName ?? "Marked") }
        speak("Tee marked for hole \(state?.currentHole ?? 0).")
    }

    func markGreen(at p: GeoCoordinate) {
        mutateCourse { c, n in c.markGreen(hole: n, at: p) }
        speak("Green marked for hole \(state?.currentHole ?? 0).")
    }

    func setPin(at p: GeoCoordinate) {
        mutateCourse { c, n in c.setPin(hole: n, at: p) }
        speak("Pin set for hole \(state?.currentHole ?? 0).")
    }

    private func mutateCourse(_ change: (inout GolfCourse, Int) -> Void) {
        guard var c = course, let n = state?.currentHole else { return }
        change(&c, n)
        course = c
        courses.save(c)
        if let p = lastPosition { update(position: p, force: true) }
    }

    // MARK: Persistence

    private func saveBag() {
        defaults.set(try? JSONEncoder().encode(bag), forKey: "clubBag")
    }

    private func saveRound() {
        defaults.set(try? JSONEncoder().encode(state), forKey: "round")
    }
}
