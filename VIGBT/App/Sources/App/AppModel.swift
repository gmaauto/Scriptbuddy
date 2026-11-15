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
        calibrationService.stop()
        calibration = cal
        capture.acousticDelaySeconds = cal.distanceToTeeMeters / 343
        arm()
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
        analysisTask = Task {
            do {
                let out = try await Task.detached(priority: .userInitiated) {
                    try await ClipAnalysisService.analyze(clip: clip, calibration: cal, profile: profile,
                                                          includeBallistics: ballistics, club: club, zone: zone)
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
            text += Readout.launch(launch)
            if let landing = shot.landing { text += " " + Readout.landing(landing) }
            else if !gate.isEnabled(.ballisticEstimation) { text += " Unlock Pro to estimate where the ball landed." }
        } else {
            text += a?.failureReason ?? "The shot could not be measured."
        }
        statusMessage = text
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
                                       includeBallistics: gate.isEnabled(.ballisticEstimation), club: club)
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

    var canWalk: Bool { currentShot?.landing != nil }

    func startWalk() {
        guard gate.isEnabled(.walkToBallNavigation) else {
            showPaywall = true
            return
        }
        guard let shot = currentShot, let target = shot.landing?.target else { return }
        let cal = shot.calibration
        AudioSessionMode.guidance.apply()
        var engine = NavigationEngine(target: target)
        engine.begin(from: cal.teeLocation)
        navigation = engine
        location.beginWalk(from: cal.teeLocation)
        beacon.start()
        phase = .navigating
        let yards = Units.yards(fromMeters: target.distanceFromTeeMeters)
        speak("Walking to your ball. \(Readout.distance(yards: yards)). Follow the beacon.")
    }

    private func navigationTick() {
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
        speak("\(Readout.distance(yards: g.distanceRemainingYards)). \(dir)", interrupt: true)
    }

    // MARK: Homing (Phase 4)

    func startHoming() {
        guard gate.isEnabled(.hapticHoming) else {
            showPaywall = true
            return
        }
        stopGuidance()
        location.endWalk()
        homing.reset()
        homingStatus = "Searching"
        highlightImage = nil
        scanner.highlightPalette = effectivePalette
        scanner.start(profile: profile)
        phase = .homing
        speak("Arrived at search zone. Point the phone at the ground and sweep slowly from side to side.", interrupt: true)
    }

    private func groundDetection(_ d: GroundDetection?) {
        guard phase == .homing else { return }
        for event in homing.process(d) {
            haptics.handle(event)
            switch event {
            case .peripheralDetected:
                homingStatus = "Ball in view"
                speak("Ball in view.")
            case .lost:
                homingStatus = "Searching"
                speak("Lost it. Keep sweeping.")
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
        }
        scanner.stop()
        haptics.stopTicking()
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
