import SwiftUI
import VIGBTCore

struct SimulatedShotButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Simulated shot") { model.runSimulatedShot() }
            .buttonStyle(CompactButtonStyle())
            .accessibilityHint("Runs a practice shot without a ball, to try replay and walking guidance")
    }
}

struct HistoryButton: View {
    @State private var showing = false

    var body: some View {
        Button("Shot history") { showing = true }
            .buttonStyle(CompactButtonStyle())
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
                            .font(.body).foregroundStyle(Palette.secondaryText)
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
        if let b = shot.bagClub { parts.append(b.name) } else if let club = shot.club, club != .auto { parts.append(club.displayName) }
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

/// Opens the course picker, or ends the current round.
struct CourseButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        AdaptiveStack(spacing: 8) {
            Button(model.round.isActive ? "Change course" : "Choose course and hole") { showing = true }
            if model.round.isActive {
                Button("End round") { model.round.end() }
                    .accessibilityHint("Stops the round. Your shots are kept.")
            }
        }
        .buttonStyle(CompactButtonStyle())
        .sheet(isPresented: $showing) { CourseSheet() }
    }
}
