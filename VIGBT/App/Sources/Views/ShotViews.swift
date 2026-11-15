import AVFoundation
import AVKit
import SwiftUI
import VIGBTCore

// MARK: - Replay (Phase 1.4)

/// Loops the clip at 0.25× with a tracer through the validated centroids; the exit vector arrow
/// is drawn once the tracer reaches the last centroid. VoiceOver reads the launch summary.
struct ReplayView: View {
    @Environment(AppModel.self) private var model
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
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
                }
                Text(model.statusMessage)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isSummaryElement)
                if let shot = model.currentShot, let launch = shot.launch {
                    StatsGrid(launch: launch, landing: shot.landing)
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
            .padding()
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
        guard let url = model.currentClipURL else { return }
        let item = AVPlayerItem(url: url)
        let p = AVQueuePlayer()
        p.isMuted = true
        looper = AVPlayerLooper(player: p, templateItem: item)
        p.defaultRate = 0.25
        p.play()
        player = p
    }
}

struct StatsGrid: View {
    let launch: LaunchVector
    let landing: LandingEstimate?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            row("Ball speed", String(format: "%.0f mph", launch.ballSpeedMph))
            row("Launch angle", String(format: "%.0f°", launch.launchAngleDeg))
            row("Direction", direction(launch.azimuthDeg))
            if let landing {
                row("Carry", String(format: "%.0f yd", Units.yards(fromMeters: landing.carryMeters)))
                row("Offline", direction(lateralYards: Units.yards(fromMeters: landing.lateralMeters)))
                row("Search zone", String(format: "± %.0f yd", Units.yards(fromMeters: landing.searchRadiusMeters)))
            }
        }
        .font(.title3)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).bold()
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
struct TracerPlayer: View {
    /// nil for simulated shots: the tracer then animates on its own 0.25× clock over a black frame.
    let player: AVPlayer?
    let centroids: [TrackedCentroid]
    let impactTime: Double
    let frameRate: Double
    let imageSize: CGSize

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let player {
                    PlayerLayerView(player: player)
                } else {
                    Color.black
                }
                TimelineView(.animation) { timeline in
                    Canvas { ctx, size in draw(in: &ctx, size: size, frame: currentFrame(at: timeline.date)) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func currentFrame(at date: Date) -> Int {
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
        ctx.stroke(path, with: .color(.yellow), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        for p in pts {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white))
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
            ctx.stroke(arrow, with: .color(.orange), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }
    }
}

// MARK: - Walk (Phase 3)

struct WalkView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            ScreenTitle(text: "Walking to your ball")
            if let g = model.guidance {
                Text(String(format: "%.0f", g.distanceRemainingYards))
                    .font(.system(size: 120, weight: .black, design: .rounded))
                    .accessibilityLabel(Readout.distance(yards: g.distanceRemainingYards))
                Text("yards").font(.title)
                    .accessibilityHidden(true)
                Image(systemName: "arrow.up")
                    .font(.system(size: 120, weight: .bold))
                    .rotationEffect(.degrees(g.headingErrorDeg))
                    .foregroundStyle(g.alignment == .onLine ? Palette.accent : Palette.warning)
                    .accessibilityLabel(alignmentText(g))
                Text(alignmentText(g)).font(.title2.bold())
                    .accessibilityHidden(true)
            } else {
                ProgressView("Finding your position…").controlSize(.large)
            }
            Spacer()
            BigButton(title: "Repeat distance", hint: "Speaks distance and direction") { model.repeatDistance() }
            BigButton(title: "Scan ground now", hint: "Starts the close-range ball finder", prominent: false) {
                model.startHoming()
            }
            BigButton(title: "End", prominent: false) { model.nextShotSameTee() }
        }
        .padding()
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

    var body: some View {
        VStack(spacing: 20) {
            ScreenTitle(text: "Finding your ball")
            CameraPreview(session: model.scanner.session)
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay(Circle().stroke(Palette.accent, lineWidth: 3).frame(width: 80, height: 80))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            Text(model.homingStatus)
                .font(.title2.bold())
                .accessibilityAddTraits(.updatesFrequently)
            Text("Faster ticks mean the ball is closer to the centre.").font(.body)
            Spacer()
            BigButton(title: "I found it") { model.ballFound() }
            BigButton(title: "Back to walking guidance", prominent: false) { model.backToWalking() }
        }
        .padding()
    }
}

// MARK: - Paywall

struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ScreenTitle(text: "VIGBT Pro")
            VStack(alignment: .leading, spacing: 10) {
                Label("Unlimited shots", systemImage: "infinity")
                Label("Carry distance and landing zone", systemImage: "scope")
                Label("Walk-to-ball spatial audio guidance", systemImage: "ear")
                Label("Haptic ball finder", systemImage: "hand.tap")
            }
            .font(.title3)
            Text("One-time purchase. No subscription. Works offline.").font(.headline)
            Spacer()
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
        .padding()
        .background(Palette.background)
        .foregroundStyle(Palette.text)
    }

    private var buyTitle: String {
        guard let p = model.storeService.product else { return "Loading…" }
        return "Unlock for \(p.displayPrice)"
    }
}
