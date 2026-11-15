import SwiftUI
import VIGBTCore

/// Opens the wind picker. The label states the current wind so VoiceOver users hear it without opening it.
struct WindButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        Button(label) { showing = true }
            .buttonStyle(CompactButtonStyle())
            .accessibilityHint("Sets the wind so carry and club advice allow for it")
            .sheet(isPresented: $showing) { WindSheet() }
    }

    private var label: String {
        guard let w = model.activeWind else { return "Wind: not set" }
        return "Wind: \(w.strength == .calm ? "calm" : w.strength.displayName.lowercased())"
    }
}

/// Two simple choices a golfer can make by feel: how strong, and where it comes from relative to the
/// target. Large outlined buttons, announced as selected (SPEC §11).
struct WindSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var strength: WindStrength = .calm
    @State private var direction: WindDirection = .into

    var body: some View {
        NavigationStack {
            Screen {
                ScreenTitle(text: "Wind")
                Text("Face your target. How strong is the wind, and where do you feel it coming from?")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                ChoiceRow(label: "Strength", options: WindStrength.allCases.map { ($0, $0.displayName) },
                          selected: strength) { strength = $0 }
                if strength != .calm {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Coming from").font(.headline).foregroundStyle(Palette.secondaryText)
                            .accessibilityHidden(true)
                        // Two columns, clockwise from "Into you", stacked at accessibility sizes.
                        ForEach(0..<4, id: \.self) { row in
                            AdaptiveStack(spacing: 8) {
                                directionButton(WindDirection.allCases[row * 2])
                                directionButton(WindDirection.allCases[row * 2 + 1])
                            }
                        }
                    }
                }
                BigButton(title: "Save wind") {
                    model.setWind(strength: strength, direction: direction)
                    dismiss()
                }
                BigButton(title: "Clear wind", prominent: false) {
                    model.wind = nil
                    dismiss()
                }
            }
            .background(Palette.background.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear {
            if let w = model.activeWind, let target = model.currentTargetBearing {
                strength = w.strength
                let rel = Units.normalizeBearing(w.fromBearingDeg - target)
                direction = WindDirection.allCases[Int((rel / 45).rounded()) % 8]
            }
        }
    }

    private func directionButton(_ d: WindDirection) -> some View {
        Button(d.displayName) { direction = d }
            .buttonStyle(VIGBTButtonStyle(prominent: d == direction))
            .accessibilityLabel("Wind coming from: \(d.displayName)")
            .accessibilityAddTraits(d == direction ? .isSelected : [])
    }
}

/// Setup step: turn the tripod camera to the flag (a helper can line it up), press, then turn it back to
/// the ball. Without it, VIGBT still corrects the compass from the balls the golfer finds.
struct CompassSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status).font(.headline)
                .accessibilityAddTraits(.updatesFrequently)
            if model.canSightFlag {
                Button("Sight the flag to correct the compass") { model.sightFlag() }
                    .buttonStyle(CompactButtonStyle())
                    .accessibilityHint("Point the camera at the flag first, then press. Afterwards point it back at the ball.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: String {
        let l = model.compassLearner
        if l.isCorrected {
            return String(format: "Compass corrected by %.0f°.", abs(l.errorDeg))
        }
        if model.calibrationService.headingSpread > CompassCorrection.maxSpreadDeg {
            return "Compass unsteady: move away from carts or metal."
        }
        return "Compass: will correct itself from the balls you find."
    }
}
