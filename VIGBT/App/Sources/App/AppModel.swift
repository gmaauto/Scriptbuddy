import AVFoundation
import Observation
import SwiftUI
import VIGBTCore

/// Owns every service and drives the shot state machine:
/// setup → armed → processing → replay → navigating → homing → found.
/// Only the subsystem needed for the current phase is powered (camera off while walking, etc.).
@MainActor
@Observable
final class AppModel {
    // MARK: Observable state
    private(set) var phase: ShotPhase = .setup
    private(set) var needsOnboarding: Bool
    private(set) var calibration: TeeCalibration?
    private(set) var currentShot: ShotRecord?
    private(set) var currentClipURL: URL?
    private(set) var guidance: NavigationGuidance?
    private(set) var homingStatus = "Searching"
    private(set) var statusMessage = ""
    /// Wind entered by the golfer (SPEC §12.5). Stale wind is treated as unknown.
    var wind: WindInput? {
        didSet { store.wind = wind }
    }
    var activeWind: WindInput? { wind.flatMap { $0.isStale() ? nil : $0 } }
    /// Compass correction for the current tripod setup (sighting and/or found balls).
    private(set) var compassLearner = SessionCompassLearner()
    /// How far balls are rolling today on this course (SPEC §12.6); reset each new round or day.
    private(set) var rollLearner = RollLearner()
    @ObservationIgnored private var rollLearnerDay = Calendar.current.startOfDay(for: Date())
    @ObservationIgnored private var rollLearnerRoundID: String?
    /// Raw averaged compass heading of the current setup, before correction.
    @ObservationIgnored private var rawCameraHeadingDeg: Double?
    var errorMessage: String?
    var showPaywall = false
    var profile: BallColorProfile {
        didSet { store.colorProfile = profile }
    }
    /// Club in hand, used for spin estimation (Section 6, note 3).
    var club: Club {
        didSet { store.club = club }
    }
    /// Display theme (SPEC §11). Applied at the root with `preferredColorScheme`.
    var theme: Theme {
        didSet { store.theme = theme }
    }
    /// Low-vision ball highlight on the Homing screen.
    var ballHighlightEnabled: Bool {
        didSet {
            store.ballHighlightEnabled = ballHighlightEnabled
            scanner.highlightEnabled = ballHighlightEnabled
        }
    }
    /// Latest ball-highlight frame from the ground scanner.
    private(set) var highlightImage: CGImage?
    /// The specific club in hand (Phase 5.3). Setting it also sets the spin category.
    var bagClub: BagClub? {
        didSet { if let b = bagClub { club = b.spinCategory } }
    }
    /// True once the golfer picks a club by hand; the recommendation then stops overriding it until the next shot.
    @ObservationIgnored var clubOverridden = false

    // MARK: Services
    let storeService = StoreService()
    let calibrationService = CalibrationService()
    let location = LocationService()
    let round = RoundModel()
    @ObservationIgnored let capture = CaptureService()
    @ObservationIgnored let scanner = GroundScanService()
    @ObservationIgnored let store = ShotStore()
    @ObservationIgnored private let speech = SpeechService()
    @ObservationIgnored private let beacon = AudioBeaconService()
    @ObservationIgnored private let haptics = HapticsService()
    @ObservationIgnored private var navigation: NavigationEngine?
    /// Guided search inside the search ellipse (SPEC §12.7) and the beacon target for its current leg.
    @ObservationIgnored private var searchGuide: SearchGuide?
    @ObservationIgnored private var searchNav: NavigationEngine?
    @ObservationIgnored private var searchLegIndex = -1
    @ObservationIgnored private var ballInView = false
    @ObservationIgnored private var homing = HomingController()
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?

    var gate: EntitlementGate { EntitlementGate(tier: storeService.tier) }
    var shotsLeftToday: Int {
        max(0, EntitlementGate.freeShotsPerDay - store.quota.shots(on: Date()))
    }

    init() {
        let s = ShotStore()
        needsOnboarding = !s.hasAcceptedDisclaimer
        profile = s.colorProfile
        club = s.club
        wind = s.wind
        theme = s.theme
        ballHighlightEnabled = s.ballHighlightEnabled
        wireCallbacks()
        scanner.highlightEnabled = ballHighlightEnabled
        if !s.lockedFiles.isEmpty {
            errorMessage = "Some of your data was saved by a newer version of VIGBT. It has been kept safe and unchanged. Please update the app to see it."
        }
    }

    // MARK: Onboarding

    func acceptDisclaimer() async {
        store.hasAcceptedDisclaimer = true
        _ = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVAudioApplication.requestRecordPermission()
        location.requestPermission()
        needsOnboarding = false
        beginCalibration()
    }

    // MARK: Setup / calibration (Phase 1.2)

    func beginCalibration() {
        stopEverything()
        phase = .setup
        calibration = nil
        // New tripod setup: its compass error is unknown again.
        compassLearner = SessionCompassLearner()
        rawCameraHeadingDeg = nil
        location.start()
        calibrationService.start()
        if case .unsupported(let why) = calibrationService.state {
            errorMessage = why
            speak(why)
            return
        }
        speak("Point the camera at the ball on the tee and hold the phone still.")
    }

    /// Tap-to-sample at the centre of the camera view (point the camera at the ball).
    func sampleBallColor() {
        if let p = calibrationService.sampleCenterPatch().flatMap({ BallColorProfile.sampled(from: $0) }) {
            profile = p
            haptics.confirm()
            speak("Ball colour sampled.")
        } else {
            speak("Could not sample the colour. Try again.")
        }
    }

    func finishCalibration() {
        do {
            try capture.configure()
        } catch {
            report(error)
            return
        }
        guard let tee = location.teeFix else {
            speak("Waiting for a GPS fix. Stay near the tee.")
            statusMessage = "Waiting for GPS…"
            return
        }
        guard let cal = calibrationService.makeCalibration(
            fieldOfViewDegrees: capture.fieldOfViewDegrees,
            width: capture.dimensions.width, height: capture.dimensions.height, teeLocation: tee) else {
            speak("Tee distance is not locked yet. Hold the phone still.")
            return
        }
        if calibrationService.headingSpread > CompassCorrection.maxSpreadDeg {
            speak("The compass is unsteady. Metal nearby, such as a cart or a steel stand, can upset it. "
                  + "The shot will still be measured, with a wider search zone.")
        }
        calibrationService.stop()
        rawCameraHeadingDeg = cal.cameraHeadingDeg
        calibration = correctedCalibration(cal)
        capture.acousticDelaySeconds = cal.distanceToTeeMeters / 343
        arm()
    }

    /// Firmness belongs to one course on one day: start learning afresh for a new round or a new day.
    private func refreshRollLearnerScope() {
        let today = Calendar.current.startOfDay(for: Date())
        let roundKey = self.round.state.map { "\($0.courseID)#\($0.startingHole)" }
        if today != rollLearnerDay || roundKey != rollLearnerRoundID {
            rollLearner = RollLearner()
            rollLearnerDay = today
            rollLearnerRoundID = roundKey
        }
    }

    /// Applies the current compass correction to a calibration built from the raw heading.
    private func correctedCalibration(_ cal: TeeCalibration) -> TeeCalibration {
        var c = cal
        let raw = rawCameraHeadingDeg ?? cal.cameraHeadingDeg
        c.cameraHeadingDeg = compassLearner.corrected(raw)
        c.compassCorrectionDeg = compassLearner.errorDeg
        return c
    }

    // MARK: Compass sighting (SPEC §12.5)

    /// Whether a flag position is known for sighting (current hole's pin or green).
    var canSightFlag: Bool { round.currentHole?.target != nil }

    /// With the tripod camera turned to point at the flag (a helper can line it up), measure the compass
    /// error against the GPS bearing tee → flag. Then turn the camera back to the ball on the tee.
    func sightFlag() {
        guard let flag = round.currentHole?.target else {
            speak("No flag position is known for this hole. Mark the pin, or skip this step: VIGBT will correct the compass from the balls you find.")
            return
        }
        guard let tee = location.teeFix else {
            speak("Waiting for a GPS fix. Stay near the tee.")
            return
        }
        let sighted = calibrationService.averagedHeading(last: 5)
        let error = CompassCorrection.sightingError(sightedHeadingDeg: sighted, tee: tee, flag: flag)
        guard abs(error) <= 25 else {
            speak("That reading is too far off to trust. Make sure the camera is pointing at the flag, then try again.")
            return
        }
        compassLearner = SessionCompassLearner()
        compassLearner.addSighting(errorDeg: error)
        haptics.confirm()
        speak(String(format: "Compass corrected by %.0f degrees. Now turn the camera back to the ball on the tee.", abs(compassLearner.errorDeg)))
    }

    // MARK: Wind (SPEC §12.5)

    /// Target bearing used to turn "into you / from the left" into a compass bearing.
    var currentTargetBearing: Double? {
        if let p = currentPosition, let t = round.currentHole?.target { return GeoMath.bearing(from: p, to: t) }
        if let c = calibration { return c.cameraHeadingDeg }
        return location.heading
    }

    func setWind(strength: WindStrength, direction: WindDirection) {
        guard let bearing = currentTargetBearing else {
            speak("Waiting for your direction. Try again in a moment.")
            return
        }
        let w = WindInput(strength: strength, direction: direction, targetBearingDeg: bearing)
        wind = w
        speak(w.description(targetBearingDeg: bearing))
        if let p = currentPosition { round.update(position: p, force: true) }
    }

    // MARK: Capture (Phase 1.1)

    func arm() {
        guard calibration != nil else { return beginCalibration() }
        guard gate.canCaptureShot(quota: store.quota, now: Date()) else {
            speak("You have used your three free shots for today. Unlock Pro for unlimited shots.")
            showPaywall = true
            return
        }
        stopGuidance()
        AudioSessionMode.capture.apply()
        do {
            try capture.arm()
        } catch {
            report(error)
            return
        }
        phase = .armed
        statusMessage = "Ready"
        speak("Ready. Take your shot.")
    }

    func testStrike() {
        capture.testStrike()
    }

    private func impactDetected() {
        guard phase == .armed else { return }
        phase = .processing
        statusMessage = "Shot captured. Measuring…"
        haptics.confirm()
        speak("Shot captured. Measuring.")
    }

    private func clipReady(_ result: Result<CapturedClip, Error>) {
        switch result {
        case .failure(let error):
            report(error)
            phase = .armed
            arm()
        case .success(let clip):
            store.recordShotTaken()
            analyze(clip)
        }
    }

    // MARK: Analysis (Phases 1.3 – 2)

    private func analyze(_ clip: CapturedClip) {
        guard let cal = calibration else { return }
        let profile = profile
        let club = club
        let ballistics = gate.isEnabled(.ballisticEstimation)
        let zone = SearchZoneModel.calibration(for: club, shots: store.shots)
        let windVector = activeWind?.vector(cameraHeadingDeg: cal.cameraHeadingDeg) ?? .zero
        let corrected = compassLearner.isCorrected && activeWind != nil
        refreshRollLearnerScope()
        let roll = rollLearner.multiplier
        let surfaces = round.currentHole.map(SurfaceMap.init(hole:))
        analysisTask = Task {
            do {
                let out = try await Task.detached(priority: .userInitiated) {
                    try await ClipAnalysisService.analyze(clip: clip, calibration: cal, profile: profile,
                                                          includeBallistics: ballistics, club: club, zone: zone,
                                                          wind: windVector, compassAndWindCorrected: corrected,
                                                          rollMultiplier: roll, surfaceMap: surfaces)
                }.value
                let a = out.analysis
                let shot = ShotRecord(ballProfile: profile, calibration: cal, centroids: a.centroids,
                                      launch: a.launch, spin: a.spin, trajectory: a.trajectory,
                                      landing: a.landing, clipFileName: clip.url.lastPathComponent, club: club,
                                      clipImpactTime: clip.impactTime, clipFrameRate: clip.frameRate,
                                      bagClub: bagClub, holeNumber: round.state?.currentHole)
                store.add(shot)
                round.record(shot: shot)
                round.learn(from: store.shots)
                clubOverridden = false
                present(shot, analysis: a, clipURL: clip.url)
            } catch {
                report(error)
                arm()
            }
        }
    }

    private func present(_ shot: ShotRecord, analysis a: ShotAnalysis?, clipURL: URL?) {
        currentShot = shot
        currentClipURL = clipURL
        phase = .replay
        var text = shot.isSimulated == true ? "Simulated shot. " : ""
        if let launch = shot.launch {
            text += Readout.shotSummary(launch: launch, landing: shot.landing)
            if shot.landing == nil, !gate.isEnabled(.ballisticEstimation) { text += " Unlock Pro to estimate where the ball landed." }
        } else {
            text += a?.failureReason ?? "The shot could not be measured."
        }
        statusMessage = text
        if shot.landsInWater { haptics.warn() }
        speak(text)
    }

    // MARK: Simulated shot & history

    /// Runs the full pipeline on a synthetic shot: works in the Simulator and needs no ball, camera or LiDAR.
    /// Does not count toward the free-tier daily limit.
    func runSimulatedShot() {
        stopEverything()
        let launch = LaunchVector(ballSpeed: Units.metersPerSecond(fromMph: .random(in: 95...150)),
                                  launchAngleDeg: .random(in: 10...20), azimuthDeg: .random(in: -5...5))
        let tee = location.teeFix
            ?? location.lastFix.map { GeoCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
            ?? GeoCoordinate(latitude: 37.3349, longitude: -122.0090) // Simulator's default location
        let sim = ShotSimulator.make(launch: launch, teeLocation: tee, cameraHeadingDeg: location.heading ?? 0)
        let a = ShotAnalyzer().analyze(frames: sim.frames, calibration: sim.calibration,
                                       referenceRadiusPixels: sim.referenceRadiusPixels,
                                       includeBallistics: gate.isEnabled(.ballisticEstimation), club: club,
                                       wind: activeWind?.vector(cameraHeadingDeg: sim.calibration.cameraHeadingDeg) ?? .zero)
        calibration = sim.calibration
        let shot = ShotRecord(ballProfile: profile, calibration: sim.calibration, centroids: a.centroids,
                              launch: a.launch, spin: a.spin, trajectory: a.trajectory, landing: a.landing,
                              club: club, clipFrameRate: 120, isSimulated: true, bagClub: bagClub,
                              holeNumber: round.state?.currentHole)
        store.add(shot)
        present(shot, analysis: a, clipURL: nil)
    }

    var shots: [ShotRecord] { store.shots }

    func open(_ shot: ShotRecord) {
        stopEverything()
        present(shot, analysis: nil, clipURL: store.clipURL(for: shot))
    }

    // MARK: Walk to ball (Phase 3)

    /// Walking guidance is not offered when the ball is predicted to be in water; the golfer gets "Drop a ball".
    var canWalk: Bool { currentShot?.landing != nil && currentShot?.landsInWater != true }
    var canDrop: Bool { currentShot?.landsInWater == true }

    /// Records a penalty drop for a ball predicted in water, then starts setup at the drop spot.
    func dropBall() {
        if var shot = currentShot, shot.isSimulated != true {
            shot.droppedFromWater = true
            store.update(shot)
            currentShot = shot
        }
        // Spoken first; setup's own prompt queues after it.
        speak(Readout.dropInstructions, interrupt: true)
        beginCalibration()
    }

    func startWalk() {
        guard gate.isEnabled(.walkToBallNavigation) else {
            showPaywall = true
            return
        }
        guard let shot = currentShot, let landing = shot.landing else { return }
        let cal = shot.calibration
        AudioSessionMode.guidance.apply()
        // Walk to the NEAR end of the search zone, where scanning starts (SPEC §12.7), not to its centre.
        let guide = SearchGuide(landing: landing, tee: cal.teeLocation, detectionRangeMeters: detectionRange)
        searchGuide = guide
        searchLegIndex = -1
        let entry = guide.entryPoint
        let entryTarget = TargetCoordinate(coordinate: entry, bearingFromTeeDeg: GeoMath.bearing(from: cal.teeLocation, to: entry),
                                           distanceFromTeeMeters: GeoMath.distance(from: cal.teeLocation, to: entry),
                                           searchRadiusMeters: landing.searchRadiusMeters)
        var engine = NavigationEngine(target: entryTarget, arrivalRadiusMeters: 5)
        engine.begin(from: cal.teeLocation)
        navigation = engine
        location.beginWalk(from: cal.teeLocation)
        beacon.start()
        phase = .navigating
        let yards = Units.yards(fromMeters: entryTarget.distanceFromTeeMeters)
        speak("\(Readout.distanceToSearchZone(yards: yards)). Follow the beacon.")
    }

    /// Ground-scanner detection range: a coloured ball stands out further away than a white one (§12.7).
    private var detectionRange: Double { DetectionRange.meters(preset: profile.preset, model: scanner.detectorInfo) }

    private func navigationTick() {
        if phase == .homing { return searchTick() }
        guard phase == .navigating, var nav = navigation, let position = location.smoothedPosition else { return }
        // Compass first; then GPS course while walking; with neither (e.g. the Simulator) assume on line.
        let course = location.lastFix.flatMap { $0.course >= 0 && $0.speed > 0.3 ? $0.course : nil }
        let heading = location.heading ?? course ?? GeoMath.bearing(from: position, to: nav.target.coordinate)
        let g = nav.update(position: position, headingDeg: heading)
        navigation = nav
        guidance = g
        beacon.update(g)
        for m in g.milestones { speak(m.announcement, interrupt: true) }
        if g.hasArrived { startHoming() }
    }

    func repeatDistance() {
        guard let g = guidance else { return }
        let dir: String
        switch g.alignment {
        case .onLine: dir = "You are on line."
        case .offLeft: dir = "Turn left."
        case .offRight: dir = "Turn right."
        }
        speak("\(Readout.distanceToSearchZone(yards: g.distanceRemainingYards)). \(dir)", interrupt: true)
    }

    // MARK: Homing (Phase 4)

    func startHoming() {
        guard gate.isEnabled(.hapticHoming) else {
            showPaywall = true
            return
        }
        navigation = nil
        guidance = nil
        homing.reset()
        ballInView = false
        homingStatus = "Searching"
        highlightImage = nil
        scanner.highlightPalette = effectivePalette
        scanner.start(profile: profile)
        phase = .homing
        if searchGuide == nil {
            beacon.stop()
            location.endWalk()
        }
        speak("Search zone. Point the phone at the ground ahead and sweep slowly from side to side as you walk. "
              + "Follow the beacon along the search path.", interrupt: true)
        searchTick()
    }

    /// Search mode: the camera scans while the beacon leads along the search pattern's legs.
    private func searchTick() {
        guard phase == .homing, var guide = searchGuide, let position = currentPosition else { return }
        if let instruction = guide.update(position: position) { speak(instruction, interrupt: true) }
        searchGuide = guide
        homingStatus = ballInView ? homingStatus : "Searching. \(guide.progressText)"
        guard let wp = guide.currentWaypoint else {
            beacon.stop()
            return
        }
        if guide.index != searchLegIndex {
            searchLegIndex = guide.index
            let t = TargetCoordinate(coordinate: wp, bearingFromTeeDeg: GeoMath.bearing(from: position, to: wp),
                                     distanceFromTeeMeters: GeoMath.distance(from: position, to: wp), searchRadiusMeters: 4)
            var nav = NavigationEngine(target: t, arrivalRadiusMeters: guide.reachRadiusMeters)
            nav.begin(from: position)
            searchNav = nav
        }
        guard !ballInView, var nav = searchNav else { return }
        let heading = location.heading ?? GeoMath.bearing(from: position, to: wp)
        beacon.update(nav.update(position: position, headingDeg: heading))
        searchNav = nav
    }

    private func groundDetection(_ d: GroundDetection?) {
        guard phase == .homing else { return }
        for event in homing.process(d) {
            haptics.handle(event)
            switch event {
            case .peripheralDetected:
                // Haptics take over: pause the search beacon so the ticks are easy to follow.
                ballInView = true
                beacon.stop()
                homingStatus = "Ball in view"
                speak("Ball in view.")
            case .lost:
                ballInView = false
                homingStatus = "Searching"
                speak("Lost it. Keep sweeping.")
                if searchGuide?.isFinished == false { beacon.start() }
            case .locked:
                ballFound()
            case .tick:
                if let dist = d?.distanceMeters { homingStatus = String(format: "Ball in view, about %.0f metres", dist) }
            }
        }
    }

    func ballFound() {
        // Ground truth for the learned search zone, and the start point for the next club recommendation.
        if var shot = currentShot, shot.isSimulated != true, let p = currentPosition {
            shot.foundLocation = p
            store.update(shot)
            currentShot = shot
            // Each found ball shows this setup's compass error; later shots from the same tripod use it.
            if let target = shot.landing?.target.coordinate, shot.calibration.teeLocation == calibration?.teeLocation {
                compassLearner.recordFoundBall(tee: shot.calibration.teeLocation, predicted: target, found: p,
                                               appliedErrorDeg: shot.calibration.compassCorrectionDeg ?? 0)
                if let cal = calibration { calibration = correctedCalibration(cal) }
            }
            // …and how far balls roll on this course today.
            if let landing = shot.landing {
                refreshRollLearnerScope()
                let found = ShotFrame.local(p, tee: shot.calibration.teeLocation, headingDeg: shot.calibration.cameraHeadingDeg)
                rollLearner.record(landing: (landing.carryMeters, landing.lateralMeters),
                                   nominalRest: landing.nominalRest, found: found)
            }
        }
        scanner.stop()
        haptics.stopTicking()
        stopGuidance()
        location.endWalk()
        beacon.playSuccessChime()
        phase = .found
        speak("Ball found. It is straight ahead of the camera, within two metres.", interrupt: true)
    }

    func backToWalking() {
        scanner.stop()
        haptics.stopTicking()
        startWalk()
    }

    // MARK: Lifecycle

    func nextShotSameTee() {
        stopEverything()
        arm()
    }

    func stopEverything() {
        analysisTask?.cancel()
        capture.disarm()
        calibrationService.stop()
        scanner.stop()
        stopGuidance()
        location.endWalk()
        haptics.stopTicking()
    }

    private func stopGuidance() {
        beacon.stop()
        navigation = nil
        guidance = nil
        searchGuide = nil
        searchNav = nil
        searchLegIndex = -1
        ballInView = false
    }

    private func wireCallbacks() {
        capture.onImpact = { [weak self] in self?.impactDetected() }
        capture.onClip = { [weak self] in self?.clipReady($0) }
        scanner.onDetection = { [weak self] in self?.groundDetection($0) }
        scanner.onHighlight = { [weak self] in self?.highlightImage = $0 }
        location.onUpdate = { [weak self] in
            guard let self else { return }
            self.navigationTick()
            if let p = self.currentPosition { self.round.update(position: p) }
        }
        round.speak = { [weak self] in self?.speak($0) }
        round.windProvider = { [weak self] in self?.activeWind }
        round.onRecommendedClub = { [weak self] club in
            guard let self, !self.clubOverridden else { return }
            self.bagClub = club
        }
        calibrationService.onStable = { [weak self] d in
            self?.haptics.confirm()
            self?.speak(String(format: "Tee distance %.1f metres. Locked. Press Start.", d))
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.thermalChanged() }
        }
    }

    /// The palette currently on screen (resolves "Match system").
    var effectivePalette: ThemePalette {
        ThemePalette.palette(for: theme, systemIsDark: UITraitCollection.current.userInterfaceStyle != .light)
    }

    /// Best current position: the smoothed walking position, else the latest GPS fix.
    var currentPosition: GeoCoordinate? {
        location.smoothedPosition ?? location.lastFix.map {
            GeoCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
    }

    private func thermalChanged() {
        let state = ProcessInfo.processInfo.thermalState
        guard state == .serious || state == .critical, phase == .armed else { return }
        capture.disarm()
        phase = .setup
        let msg = "The phone is too hot. Recording is paused. Move it into the shade for a few minutes."
        errorMessage = msg
        speak(msg, interrupt: true)
    }

    private func report(_ error: Error) {
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = msg
        speak(msg, interrupt: true)
    }

    /// For views that need to read something aloud (e.g. the hole description).
    func speakText(_ text: String) {
        speak(text, interrupt: true)
    }

    private func speak(_ text: String, interrupt: Bool = false) {
        speech.say(text, interrupt: interrupt)
    }
}
