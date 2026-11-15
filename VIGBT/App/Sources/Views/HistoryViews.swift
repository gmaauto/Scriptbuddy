import SwiftUI
import VIGBTCore

/// Club in hand: drives spin estimation, which matters most for irons.
struct ClubPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("Club", selection: $model.club) {
            ForEach(Club.allCases) { club in
                Text(club.displayName).tag(club)
            }
        }
        .pickerStyle(.menu)
        .font(.title2)
        .tint(Palette.accent)
        .accessibilityLabel("Club: \(model.club.displayName)")
        .accessibilityHint("Choosing your club makes the carry estimate more accurate")
    }
}

struct SimulatedShotButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Simulated shot") { model.runSimulatedShot() }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 48)
            .accessibilityHint("Runs a practice shot without a ball, to try replay and walking guidance")
    }
}

struct HistoryButton: View {
    @State private var showing = false

    var body: some View {
        Button("Shot history") { showing = true }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 48)
            .sheet(isPresented: $showing) { HistoryView() }
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(model.shots) { shot in
                Button {
                    model.open(shot)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(shot)).font(.title3.bold())
                        Text(shot.capturedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens the replay")
            }
            .overlay {
                if model.shots.isEmpty {
                    Text("No shots yet.").font(.title2)
                }
            }
            .navigationTitle("Shot history")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func title(_ shot: ShotRecord) -> String {
        var parts: [String] = []
        if shot.isSimulated == true { parts.append("Simulated") }
        if let club = shot.club, club != .auto { parts.append(club.displayName) }
        if let l = shot.landing {
            parts.append(String(format: "%.0f yd carry", Units.yards(fromMeters: l.carryMeters)))
        } else if let launch = shot.launch {
            parts.append(String(format: "%.0f mph", launch.ballSpeedMph))
        } else {
            parts.append("Not measured")
        }
        return parts.joined(separator: ", ")
    }
}
