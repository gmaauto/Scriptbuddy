import AVFoundation
import AVKit
import SwiftUI
import VIGBTCore

// MARK: - Replay (Phase 1.4)

/// Loops the clip at 0.25× with a tracer through the validated centroids; the exit vector arrow
/// is drawn once the tracer reaches the last centroid. VoiceOver reads the launch summary.
/// With Reduce Motion on, nothing plays automatically and the tracer is shown complete.
struct ReplayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var playing = false

    var body: some View {
        Screen {
            ScreenTitle(text: model.currentShot?.launch == nil ? "Shot not measured" : "Your shot")
            if let shot = model.currentShot {
                TracerPlayer(player: player,
                             centroids: shot.centroids,
                             impactTime: shot.clipImpactTime ?? 0,
                             frameRate: shot.clipFrameRate ?? 120,
                             imageSize: CGSize(width: shot.calibration.imageWidth,
                                               height: shot.calibration.imageHeight))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                if player != nil {
                    Button(playing ? "Pause replay" : "Play slow-motion replay") { togglePlayback() }
                        .buttonStyle(CompactButtonStyle())
                }
            }
            Text(model.statusMessage)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isSummaryElement)
            if let shot = model.currentShot, let launch = shot.launch {
                StatsList(launch: launch, landing: shot.landing)
            }
            if model.canWalk {
                BigButton(title: "Walk to ball", hint: "Starts audio guidance to the landing zone") { model.startWalk() }
            } else if model.currentShot?.launch != nil, model.storeService.tier == .free {
                BigButton(title: "Unlock landing zone", hint: "Opens the Pro upgrade") { model.showPaywall = true }
            }
            BigButton(title: "Next shot (same tee)", prominent: !model.canWalk) { model.nextShotSameTee() }
            BigButton(title: "New tee", prominent: false) { model.beginCalibration() }
            HistoryButton()
        }
        .onAppear(perform: setUpPlayer)
        .onChange(of: model.currentShot?.id) { setUpPlayer() }
        .onDisappear {
            player?.pause()
            looper = nil
            player = nil
        }
    }

    private func setUpPlayer() {
        player?.pause()
        looper = nil
        player = nil
        playing = false
        guard let url = model.currentClipURL else { return }
        let p = AVQueuePlayer()
        p.isMuted = true
        looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url))
        p.defaultRate = 0.25
        player = p
        if !reduceMotion { togglePlayback() }
    }

    private func togglePlayback() {
        guard let p = player else { return }
        if playing { p.pause() } else { p.play() }
        playing.toggle()
    }
}

/// Label/value rows that stack vertically at accessibility text sizes.
struct StatsList: View {
    let launch: LaunchVector
    let landing: LandingEstimate?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Ball speed", String(format: "%.0f mph", launch.ballSpeedMph))
            row("Launch angle", String(format: "%.0f°", launch.launchAngleDeg))
            row("Direction", direction(launch.azimuthDeg))
            if let landing {
                row("Carry", String(format: "%.0f yd", Units.yards(fromMeters: landing.carryMeters)))
                row("Offline", direction(lateralYards: Units.yards(fromMeters: landing.lateralMeters)))
                if let surface = landing.landingSurface {
                    row("Lands", surface.rawValue.capitalized)
                }
                row("Expected stop", String(format: "%.0f yd", Units.yards(fromMeters: landing.restCarry)))
                if let a = landing.searchAlongMeters, let c = landing.searchLateralMeters {
                    row("Search zone", String(format: "± %.0f yd long, ± %.0f yd wide",
                                              Units.yards(fromMeters: a), Units.yards(fromMeters: c)))
                } else {
                    row("Search zone", String(format: "± %.0f yd", Units.yards(fromMeters: landing.searchRadiusMeters)))
                }
            }
        }
        .font(.title3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
    }

    private func row(_ label: String, _ value: String) -> some View {
        AdaptiveStack(spacing: 4) {
            Text(label).foregroundStyle(Palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value).bold()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func direction(_ deg: Double) -> String {
        abs(deg) < 1 ? "Straight" : String(format: "%.0f° %@", abs(deg), deg > 0 ? "right" : "left")
    }

    private func direction(lateralYards y: Double) -> String {
        abs(y) < 2 ? "On line" : String(format: "%.0f yd %@", abs(y), y > 0 ? "right" : "left")
    }
}

/// Video layer + Canvas overlay. Centroids are in capture-pixel coordinates.
/// The tracer is drawn yellow over a black halo so it stays ≥ 3:1 against any video content.
struct TracerPlayer: View {
    /// nil for simulated shots: the tracer then animates on its own 0.25× clock over a black frame.
    let player: AVPlayer?
    let centroids: [TrackedCentroid]
    let impactTime: Double
    let frameRate: Double
    let imageSize: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let tracer = Color(UIColor(ThemePalette.highContrastDark.accent))
    private static let arrow = Color(UIColor(ThemePalette.highContrastDark.warning))

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let player {
                    PlayerLayerView(player: player)
                } else {
                    Color.black
                }
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    Canvas { ctx, size in draw(in: &ctx, size: size, frame: currentFrame(at: timeline.date)) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityIgnoresInvertColors()
    }

    private func currentFrame(at date: Date) -> Int {
        if reduceMotion { return .max } // still image of the complete tracer
        if let player {
            return Int(((player.currentTime().seconds - impactTime) * frameRate).rounded(.down))
        }
        // Synthetic loop: 0.25× speed, then hold the finished tracer for ~2 s before repeating.
        let span = Double((centroids.last?.frameOffset ?? 0) + 60)
        let f = (date.timeIntervalSinceReferenceDate * 0.25 * frameRate).truncatingRemainder(dividingBy: span)
        return Int(f)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, frame: Int) {
        guard centroids.count >= 2 else { return }
        // Aspect-fit mapping from image pixels to view points.
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let ox = (size.width - imageSize.width * scale) / 2
        let oy = (size.height - imageSize.height * scale) / 2
        func pt(_ c: TrackedCentroid) -> CGPoint { CGPoint(x: ox + c.x * scale, y: oy + c.y * scale) }

        let visible = centroids.filter { $0.frameOffset <= frame }
        guard let first = visible.first else { return }

        var path = Path()
        path.move(to: pt(first))
        // Catmull-Rom → cubic Bézier spline through the visible centroids.
        let pts = visible.map(pt)
        for i in 1..<max(1, pts.count) {
            let p0 = pts[max(0, i - 2)], p1 = pts[i - 1], p2 = pts[i], p3 = pts[min(pts.count - 1, i + 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        let style = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
        ctx.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
        ctx.stroke(path, with: .color(Self.tracer), style: style)
        for p in pts {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.white))
        }

        // Exit-vector arrow once the whole track is shown.
        if visible.count == centroids.count, let a = pts.dropLast().last, let b = pts.last {
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(1, (dx * dx + dy * dy).squareRoot())
            let ux = dx / len, uy = dy / len
            let tip = CGPoint(x: b.x + ux * 60, y: b.y + uy * 60)
            var arrow = Path()
            arrow.move(to: b)
            arrow.addLine(to: tip)
            arrow.move(to: CGPoint(x: tip.x - ux * 14 - uy * 9, y: tip.y - uy * 14 + ux * 9))
            arrow.addLine(to: tip)
            arrow.addLine(to: CGPoint(x: tip.x - ux * 14 + uy * 9, y: tip.y - uy * 14 - ux * 9))
            ctx.stroke(arrow, with: .color(.black), style: StrokeStyle(lineWidth: 10, lineCap: .round))
            ctx.stroke(arrow, with: .color(Self.arrow), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }
    }
}

// MARK: - Walk (Phase 3)

struct WalkView: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var bigNumber: CGFloat = 96
    @ScaledMetric(relativeTo: .largeTitle) private var arrowSize: CGFloat = 88

    var body: some View {
        Screen {
            ScreenTitle(text: "Walking to your ball")
            if let g = model.guidance {
                Text(String(format: "%.0f", g.distanceRemainingYards))
                    .font(.system(size: bigNumber, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityLabel(Readout.distanceToSearchZone(yards: g.distanceRemainingYards))
                Text("yards to the search zone").font(.title)
                    .multilineTextAlignment(.center)
                    .accessibilityHidden(true)
                Image(systemName: g.alignment == .onLine ? "arrow.up.circle.fill" : "arrow.up")
                    .font(.system(size: arrowSize, weight: .bold))
                    .rotationEffect(.degrees(g.headingErrorDeg))
                    .foregroundStyle(g.alignment == .onLine ? Palette.success : Palette.warning)
                    .accessibilityLabel(alignmentText(g))
                // Direction is always stated in words too, never by colour alone.
                Text(alignmentText(g)).font(.title.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityHidden(true)
            } else {
                ProgressView("Finding your position…")
                    .controlSize(.large)
                    .font(.title3)
            }
            BigButton(title: "Repeat distance", hint: "Speaks distance and direction") { model.repeatDistance() }
            BigButton(title: "Scan ground now", hint: "Starts the close-range ball finder", prominent: false) {
                model.startHoming()
            }
            BigButton(title: "End", prominent: false) { model.nextShotSameTee() }
        }
    }

    private func alignmentText(_ g: NavigationGuidance) -> String {
        switch g.alignment {
        case .onLine: return "On line"
        case .offLeft: return String(format: "Turn left %.0f degrees", abs(g.headingErrorDeg))
        case .offRight: return String(format: "Turn right %.0f degrees", abs(g.headingErrorDeg))
        }
    }
}

// MARK: - Homing (Phase 4)

struct HomingView: View {
    @Environment(AppModel.self) private var model
    @State private var zoom: CGFloat = 1

    var body: some View {
        Screen {
            ScreenTitle(text: "Finding your ball")
            ZStack {
                CameraPreview(session: model.scanner.session)
                    .opacity(showHighlight ? 0 : 1)
                if showHighlight, let image = model.highlightImage {
                    // Sensor-native landscape buffer → rotate for the portrait UI.
                    Image(decorative: image, scale: 1, orientation: .right)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .scaleEffect(zoom)
                }
            }
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay(Circle().stroke(Palette.accent, lineWidth: 4).frame(width: 80, height: 80))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
            .accessibilityIgnoresInvertColors()

            Text(model.homingStatus)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)
            Text("Faster ticks mean the ball is closer to the centre.").font(.body)

            if model.ballHighlightEnabled {
                AdaptiveStack(spacing: 8) {
                    Button("Zoom out") { zoom = max(1, zoom - 1) }
                        .disabled(zoom <= 1)
                    Text("Zoom \(Int(zoom))×").font(.headline)
                        .frame(minWidth: 80)
                    Button("Zoom in") { zoom = min(4, zoom + 1) }
                        .disabled(zoom >= 4)
                }
                .buttonStyle(CompactButtonStyle())
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Ball highlight zoom")
            }
            BigButton(title: "I found it") { model.ballFound() }
            BigButton(title: "Back to walking guidance", prominent: false) { model.backToWalking() }
        }
    }

    private var showHighlight: Bool { model.ballHighlightEnabled && model.highlightImage != nil }
}

// MARK: - Paywall

struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Screen {
            ScreenTitle(text: "VIGBT Pro")
            VStack(alignment: .leading, spacing: 12) {
                Label("Unlimited shots", systemImage: "infinity")
                Label("Carry distance and landing zone", systemImage: "scope")
                Label("Walk-to-ball spatial audio guidance", systemImage: "ear")
                Label("Haptic ball finder", systemImage: "hand.tap")
                Label("Club recommendations", systemImage: "flag")
            }
            .font(.title3)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("One-time purchase. No subscription. Works offline. VIGBT is open source: buying it supports development.")
                .font(.headline)
            BigButton(title: buyTitle) {
                Task {
                    await model.storeService.purchase()
                    if model.storeService.tier == .pro { dismiss() }
                }
            }
            .disabled(model.storeService.product == nil || model.storeService.isPurchasing)
            BigButton(title: "Restore purchase", prominent: false) {
                Task {
                    await model.storeService.restore()
                    if model.storeService.tier == .pro { dismiss() }
                }
            }
            BigButton(title: "Not now", prominent: false) { dismiss() }
            if let err = model.storeService.lastError { Text(err).foregroundStyle(Palette.warning) }
        }
        .background(Palette.background.ignoresSafeArea())
        .foregroundStyle(Palette.text)
    }

    private var buyTitle: String {
        guard let p = model.storeService.product else { return "Loading…" }
        return "Unlock for \(p.displayPrice)"
    }
}
