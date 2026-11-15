import SwiftUI
import VIGBTCore

/// High-contrast palette used everywhere.
enum Palette {
    static let background = Color.black
    static let text = Color.white
    static let accent = Color.yellow
    static let warning = Color.orange
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            Palette.background.ignoresSafeArea()
            content
        }
        .foregroundStyle(Palette.text)
        .sheet(isPresented: $model.showPaywall) { PaywallView() }
        .alert("Problem", isPresented: Binding(get: { model.errorMessage != nil },
                                               set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if model.needsOnboarding {
            OnboardingView()
        } else {
            switch model.phase {
            case .setup: SetupView()
            case .armed: ArmedView()
            case .processing: ProcessingView()
            case .replay: ReplayView()
            case .navigating: WalkView()
            case .homing: HomingView()
            case .found: FoundView()
            }
        }
    }
}

/// Full-width, tall button with a large label (≥ 64 pt touch target).
struct BigButton: View {
    let title: String
    var hint: String? = nil
    var prominent = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.title2.bold())
                .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(prominent ? Palette.accent : Color.gray.opacity(0.5))
        .foregroundStyle(prominent ? Color.black : Palette.text)
        .accessibilityHint(hint ?? "")
    }
}

struct ScreenTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.largeTitle.bold())
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ScreenTitle(text: "Welcome to VIGBT")
                Text("VIGBT measures your golf shot with the iPhone camera on a tripod at the tee, estimates where the ball landed, and guides you to it with sound and vibration.")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Safety").font(.title2.bold()).foregroundStyle(Palette.warning)
                        .accessibilityAddTraits(.isHeader)
                    Text("VIGBT is a navigation aid only. It does not detect hazards, obstacles, water, other golfers, carts or flying balls. Always use your usual mobility aids and the help of a sighted guide or caddie where you normally would.")
                        .font(.title3)
                }
                .padding()
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.warning, lineWidth: 2))
                .accessibilityElement(children: .combine)
                Text("VIGBT will ask to use the camera, microphone, location and motion sensors. Everything is processed on this iPhone and nothing is uploaded.")
                    .font(.body)
                BigButton(title: "I understand", hint: "Accepts the safety notice and asks for permissions") {
                    Task { await model.acceptDisclaimer() }
                }
            }
            .padding()
        }
    }
}

// MARK: - Setup

struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 16) {
            ScreenTitle(text: "Set up at the tee")
            ARCameraView(session: model.calibrationService.session)
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay(Image(systemName: "plus").font(.largeTitle).foregroundStyle(Palette.accent))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            Text(statusText)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)
            Picker("Ball colour", selection: Binding(
                get: { model.profile.preset },
                set: { preset in
                    switch preset {
                    case .neonOrange: model.profile = .neonOrange
                    case .neonPink: model.profile = .neonPink
                    case .sampled: model.sampleBallColor()
                    }
                })) {
                Text("Orange").tag(BallColorPreset.neonOrange)
                Text("Pink").tag(BallColorPreset.neonPink)
                Text("Sampled").tag(BallColorPreset.sampled)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Ball colour")
            BigButton(title: "Sample ball colour", hint: "Point the centre of the camera at the ball first", prominent: false) {
                model.sampleBallColor()
            }
            BigButton(title: "Start", hint: "Locks the calibration and starts listening for your shot") {
                model.finishCalibration()
            }
            .disabled(!isStable)
            if !model.statusMessage.isEmpty {
                Text(model.statusMessage).font(.headline)
            }
            HStack {
                SimulatedShotButton()
                HistoryButton()
            }
        }
        .padding()
        .onAppear {
            if case .idle = model.calibrationService.state { model.beginCalibration() }
        }
    }

    private var isStable: Bool {
        if case .stable = model.calibrationService.state { return true }
        return false
    }

    private var statusText: String {
        switch model.calibrationService.state {
        case .idle: return "Starting camera…"
        case .unsupported(let why): return why
        case .searching: return "Point the camera at the ball on the tee."
        case .measuring(let d): return String(format: "Measuring: %.1f m. Hold still.", d)
        case .stable(let d): return String(format: "Locked: %.1f m to the tee.", d)
        }
    }
}

// MARK: - Armed

struct ArmedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            ScreenTitle(text: "Ready")
            CameraPreview(session: model.capture.session)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            Text("Listening for the strike. Take your shot.")
                .font(.title2)
                .multilineTextAlignment(.center)
            if model.storeService.tier == .free {
                Text("\(model.shotsLeftToday) free shots left today").font(.headline)
            }
            ClubPicker()
            Spacer()
            BigButton(title: "Test Strike", hint: "Simulates the sound of a strike to test recording", prominent: false) {
                model.testStrike()
            }
            BigButton(title: "Recalibrate", prominent: false) { model.beginCalibration() }
            HStack {
                SimulatedShotButton()
                HistoryButton()
            }
        }
        .padding()
    }
}

struct ProcessingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            ProgressView().controlSize(.large).tint(Palette.accent)
            Text(model.statusMessage.isEmpty ? "Measuring the shot…" : model.statusMessage)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Found

struct FoundView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 120))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            ScreenTitle(text: "Ball found")
            Text("It is straight ahead of the camera, within two metres.").font(.title2)
                .multilineTextAlignment(.center)
            Spacer()
            BigButton(title: "Next shot (same tee)") { model.nextShotSameTee() }
            BigButton(title: "New tee", prominent: false) { model.beginCalibration() }
        }
        .padding()
    }
}
