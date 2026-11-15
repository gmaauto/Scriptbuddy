import SwiftUI
import VIGBTCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            Palette.background.ignoresSafeArea()
            VStack(spacing: 0) {
                if !model.needsOnboarding, model.round.isActive {
                    HoleHeader()
                }
                content
            }
        }
        .foregroundStyle(Palette.text)
        .tint(Palette.accent)
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

/// A set of mutually exclusive choices as large outlined buttons (replaces segmented controls,
/// which truncate at accessibility text sizes). The selected one is filled and announced as selected.
struct ChoiceRow<T: Hashable>: View {
    let label: String
    let options: [(T, String)]
    let selected: T
    let choose: (T) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.headline).foregroundStyle(Palette.secondaryText)
                .accessibilityHidden(true)
            AdaptiveStack(spacing: 8) {
                ForEach(options.indices, id: \.self) { i in
                    let value = options[i].0
                    let title = options[i].1
                    Button(title) { choose(value) }
                        .buttonStyle(VIGBTButtonStyle(prominent: value == selected))
                        .accessibilityLabel("\(label): \(title)")
                        .accessibilityAddTraits(value == selected ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Screen {
            ScreenTitle(text: "Welcome to VIGBT")
            Text("VIGBT measures your golf shot with the iPhone camera on a tripod at the tee, estimates where the ball landed, and guides you to it with sound and vibration.")
                .font(.title3)
            VStack(alignment: .leading, spacing: 12) {
                Label("Safety", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(Palette.warning)
                    .accessibilityAddTraits(.isHeader)
                Text("VIGBT is a navigation aid only. It does not detect hazards, obstacles, water, other golfers, carts or flying balls. Always use your usual mobility aids and the help of a sighted guide or caddie where you normally would.")
                    .font(.title3)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.warning, lineWidth: OutlineWidth.value(contrast) + 1))
            .accessibilityElement(children: .combine)
            Text("VIGBT will ask to use the camera, microphone, location and motion sensors. Everything is processed on this iPhone and nothing is uploaded.")
                .font(.body)
            BigButton(title: "I understand", hint: "Accepts the safety notice and asks for permissions") {
                Task { await model.acceptDisclaimer() }
            }
            SettingsButton()
        }
    }
}

// MARK: - Setup

struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Screen {
            ScreenTitle(text: "Set up at the tee")
            ARCameraView(session: model.calibrationService.session)
                .aspectRatio(3 / 4, contentMode: .fit)
                .frame(maxHeight: 360)
                .overlay(Image(systemName: "plus").font(.largeTitle.bold()).foregroundStyle(Palette.accent))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
                .accessibilityIgnoresInvertColors()
            Text(statusText)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)
            ChoiceRow(label: "Ball colour",
                      options: [(BallColorPreset.neonOrange, "Orange"), (.neonPink, "Pink"), (.sampled, "Sampled")],
                      selected: model.profile.preset) { preset in
                switch preset {
                case .neonOrange: model.profile = .neonOrange
                case .neonPink: model.profile = .neonPink
                case .sampled: model.sampleBallColor()
                }
            }
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
            CourseButton()
            AdaptiveStack {
                SimulatedShotButton()
                HistoryButton()
                SettingsButton()
            }
        }
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
        Screen {
            ScreenTitle(text: "Ready")
            CameraPreview(session: model.capture.session)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
                .accessibilityIgnoresInvertColors()
            Text("Listening for the strike. Take your shot.")
                .font(.title2)
                .multilineTextAlignment(.center)
            if model.storeService.tier == .free {
                Text("\(model.shotsLeftToday) free shots left today").font(.headline)
            }
            ClubPicker()
            BigButton(title: "Test Strike", hint: "Simulates the sound of a strike to test recording", prominent: false) {
                model.testStrike()
            }
            BigButton(title: "Recalibrate", prominent: false) { model.beginCalibration() }
            AdaptiveStack {
                SimulatedShotButton()
                HistoryButton()
                SettingsButton()
            }
        }
    }
}

struct ProcessingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Screen {
            ProgressView()
                .controlSize(.large)
                .tint(Palette.accent)
                .padding(.top, 40)
            Text(model.statusMessage.isEmpty ? "Measuring the shot…" : model.statusMessage)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Found

struct FoundView: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 96

    var body: some View {
        Screen {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(Palette.success)
                .accessibilityHidden(true)
            ScreenTitle(text: "Ball found")
            Text("It is straight ahead of the camera, within two metres.")
                .font(.title2)
                .multilineTextAlignment(.center)
            BigButton(title: "Next shot (same tee)") { model.nextShotSameTee() }
            BigButton(title: "New tee", prominent: false) { model.beginCalibration() }
        }
    }
}
