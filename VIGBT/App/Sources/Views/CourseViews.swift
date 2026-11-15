import SwiftUI
import UniformTypeIdentifiers
import VIGBTCore

// MARK: - Course picker (Phase 5.1)

struct CourseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: GolfCourse?
    @State private var importing = false
    @State private var newCourseName = ""
    @State private var error: String?

    private var courses: CourseService { model.round.courses }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(Palette.warning)
                }
                Section("Nearby (OpenStreetMap)") {
                    Button {
                        Task { await findNearby() }
                    } label: {
                        Label(courses.isLoading ? "Searching…" : "Find courses near me", systemImage: "location")
                    }
                    .disabled(courses.isLoading)
                    ForEach(courses.nearby) { s in
                        Button {
                            Task { await download(s) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(s.name).font(.title3.bold())
                                if let d = s.distanceMeters {
                                    Text(String(format: "%.1f km away", d / 1000)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityHint("Downloads the course once and keeps it on this phone")
                    }
                }
                Section("On this phone") {
                    if courses.saved.isEmpty { Text("No saved courses yet.") }
                    ForEach(courses.saved) { c in
                        Button { chosen = c } label: {
                            VStack(alignment: .leading) {
                                Text(c.name).font(.title3.bold())
                                Text("\(c.holes.count) holes · \(sourceName(c.source))").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in idx.map { courses.saved[$0] }.forEach(courses.delete) }
                }
                Section("Other ways to add a course") {
                    Button("Import a GeoJSON file") { importing = true }
                    HStack {
                        TextField("New course name", text: $newCourseName)
                        Button("Mark on site") { markNew() }
                            .disabled(newCourseName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .accessibilityElement(children: .contain)
                }
                Section {
                    Text("Course data © OpenStreetMap contributors, available under the Open Database License.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Choose course")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .navigationDestination(item: $chosen) { c in
                RoundSetupView(course: c) { dismiss() }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, UTType(filenameExtension: "geojson") ?? .json]) { result in
                switch result {
                case .success(let url):
                    do { chosen = try courses.importGeoJSON(from: url) } catch { self.error = "That file has no mapped holes." }
                case .failure(let e):
                    error = e.localizedDescription
                }
            }
        }
    }

    private func sourceName(_ s: CourseSource) -> String {
        switch s {
        case .openStreetMap: return "OpenStreetMap"
        case .imported: return "Imported"
        case .marked: return "Marked on site"
        }
    }

    private func findNearby() async {
        guard let p = model.currentPosition else {
            error = "Waiting for your location."
            return
        }
        error = nil
        do { try await courses.findNearby(p) } catch { self.error = error.localizedDescription }
        if courses.nearby.isEmpty, error == nil { error = "No mapped courses found nearby. Mark one on site instead." }
    }

    private func download(_ s: CourseSummary) async {
        error = nil
        do { chosen = try await courses.download(s) } catch { self.error = error.localizedDescription }
    }

    private func markNew() {
        guard let p = model.currentPosition else {
            error = "Waiting for your location."
            return
        }
        chosen = courses.newMarkedCourse(name: newCourseName.trimmingCharacters(in: .whitespaces), at: p, holes: 18)
        newCourseName = ""
    }
}

extension GolfCourse: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Round setup (Phase 5.2)

struct RoundSetupView: View {
    @Environment(AppModel.self) private var model
    let course: GolfCourse
    let done: () -> Void
    @State private var teeSet: String = ""
    @State private var startingHole: Int = 1

    var body: some View {
        Form {
            Section("Tee set") {
                if course.teeSetNames.isEmpty {
                    Text("No tees mapped. Use Mark tee on each tee box.")
                } else {
                    Picker("Tee set", selection: $teeSet) {
                        ForEach(course.teeSetNames, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            Section("Starting hole") {
                Picker("Starting hole", selection: $startingHole) {
                    ForEach(course.holeNumbers, id: \.self) { n in
                        Text(label(for: n)).tag(n)
                    }
                }
                .pickerStyle(.wheel)
                Text("Pick 10 for a back-nine start, or any hole for a shotgun start.").font(.footnote)
            }
            Section {
                BigButton(title: "Start round on hole \(startingHole)") {
                    model.round.start(course: course, teeSet: teeSet.isEmpty ? nil : teeSet, startingHole: startingHole)
                    done()
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(course.name)
        .onAppear {
            if teeSet.isEmpty { teeSet = course.teeSetNames.first ?? "" }
            startingHole = course.holeNumbers.first ?? 1
        }
    }

    private func label(for n: Int) -> String {
        guard let h = course.hole(n) else { return "Hole \(n)" }
        return h.par.map { "Hole \(n), par \($0)" } ?? "Hole \(n)"
    }
}

// MARK: - Hole header (shown on every screen during a round)

struct HoleHeader: View {
    @Environment(AppModel.self) private var model
    @State private var showLayout = false

    var body: some View {
        let round = model.round
        VStack(spacing: 8) {
            if let pending = round.pendingHole {
                HStack {
                    Button("Yes, start hole \(pending)") { round.confirmPendingHole() }
                        .buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(.black)
                    Button("Not yet") { round.dismissPendingHole() }
                }
                .font(.headline)
            }
            HStack(spacing: 12) {
                Button { round.previous() } label: { Image(systemName: "chevron.left").font(.title2.bold()) }
                    .accessibilityLabel("Previous hole")
                Button { round.announceRecommendation() } label: {
                    VStack(spacing: 2) {
                        Text(title).font(.title3.bold())
                        Text(subtitle).font(.headline).foregroundStyle(Palette.accent)
                    }
                    .frame(maxWidth: .infinity)
                }
                .accessibilityLabel("\(title). \(subtitle)")
                .accessibilityHint("Speaks the distance and club recommendation")
                Button { round.next() } label: { Image(systemName: "chevron.right").font(.title2.bold()) }
                    .accessibilityLabel("Next hole")
            }
            Button {
                showLayout = true
            } label: {
                Label("Course layout", systemImage: "map")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(Palette.accent)
            .accessibilityHint("Shows and describes the current hole. Guidance keeps running.")
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .fullScreenCover(isPresented: $showLayout) { CourseLayoutView() }
    }

    private var title: String {
        guard let h = model.round.currentHole else { return "No hole" }
        return h.par.map { "Hole \(h.number) · Par \($0)" } ?? "Hole \(h.number)"
    }

    private var subtitle: String {
        guard let d = model.round.distanceToPinMeters else { return "Distance unavailable" }
        let yards = Readout.distanceShort(meters: d)
        if let r = model.round.recommendation { return "\(yards) to pin · \(r.recommended.name)" }
        return "\(yards) to pin"
    }
}

// MARK: - Course layout (Phase 5.4)

/// Full-screen hole view drawn from open vector data (no map tiles), plus an ordered spoken description.
/// Opening it never changes `AppModel.phase`, so the beacon and haptics keep running underneath.
struct CourseLayoutView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let round = model.round
        let description = round.describeHole(golfer: model.currentPosition)
        VStack(spacing: 12) {
            ScreenTitle(text: description?.summary ?? "No hole selected")
            if let hole = round.currentHole, let geo = HoleGeometry(hole: hole) {
                HoleCanvas(geometry: geo, golfer: model.currentPosition,
                           landing: model.currentShot?.landing)
                    .accessibilityHidden(true)
                    .frame(maxHeight: .infinity)
            } else {
                Text("This hole has not been mapped. Use the buttons below while standing on the tee, on the green, or next to the hole.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .frame(maxHeight: .infinity)
            }
            if let features = description?.features, !features.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(features) { f in
                            Text(f.text)
                                .font(.headline)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).stroke(Palette.accent))
                        }
                    }
                }
                .frame(maxHeight: 70)
            }
            HStack {
                Button("Read hole") {
                    if let d = description { model.speakText(d.fullText) }
                }
                Button("Mark tee") { if let p = model.currentPosition { round.markTee(at: p) } }
                Button("Mark green") { if let p = model.currentPosition { round.markGreen(at: p) } }
                Button("Set pin here") { if let p = model.currentPosition { round.setPin(at: p) } }
            }
            .font(.headline)
            .buttonStyle(.bordered)
            .tint(Palette.accent)
            if let attribution = round.course?.attribution {
                Text(attribution).font(.caption2).foregroundStyle(.secondary)
            }
            BigButton(title: "Return", hint: "Goes back to where you were") { dismiss() }
        }
        .padding()
        .background(Palette.background.ignoresSafeArea())
        .foregroundStyle(Palette.text)
        .accessibilityAction(.escape) { dismiss() }
        .onAppear {
            if let d = description { model.speakText(d.summary) }
        }
    }
}

/// Draws the hole rotated so the tee is at the bottom and the green at the top.
struct HoleCanvas: View {
    let geometry: HoleGeometry
    let golfer: GeoCoordinate?
    let landing: LandingEstimate?

    var body: some View {
        Canvas { ctx, size in
            let hole = geometry.hole
            var all: [GeoCoordinate] = hole.playingLine + hole.fairways.flatMap { $0 } + hole.hazards.flatMap(\.outline)
            if let g = hole.green { all += g.outline + [g.front, g.back] }
            all += hole.tees.map(\.coordinate)
            let pts = all.map(geometry.layoutPoint)
            let xs = pts.map { $0.x }, ys = pts.map { $0.y }
            let minX = (xs.min() ?? -30) - 25, maxX = (xs.max() ?? 30) + 25
            let minY = (ys.min() ?? 0) - 15, maxY = (ys.max() ?? 100) + 15
            let scale = min(size.width / (maxX - minX), size.height / (maxY - minY))
            let ox = (size.width - (maxX - minX) * scale) / 2
            func p(_ c: GeoCoordinate) -> CGPoint {
                let l = geometry.layoutPoint(c)
                return CGPoint(x: ox + (l.x - minX) * scale, y: size.height - (l.y - minY) * scale)
            }
            func polygon(_ cs: [GeoCoordinate]) -> Path {
                var path = Path()
                guard let first = cs.first else { return path }
                path.move(to: p(first))
                cs.dropFirst().forEach { path.addLine(to: p($0)) }
                path.closeSubpath()
                return path
            }
            func dot(_ c: GeoCoordinate, _ r: CGFloat) -> Path {
                let q = p(c)
                return Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r))
            }

            for f in hole.fairways { ctx.fill(polygon(f), with: .color(Color(white: 0.25))) }
            for h in hole.hazards {
                let shape = h.outline.count >= 3 ? polygon(h.outline) : dot(h.outline[0], 8)
                switch h.kind {
                case .water: ctx.fill(shape, with: .color(.blue))
                case .bunker: ctx.fill(shape, with: .color(Color(red: 0.95, green: 0.85, blue: 0.55)))
                case .outOfBounds, .trees: ctx.stroke(shape, with: .color(.red), style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                }
            }
            if let g = hole.green {
                let shape = g.outline.count >= 3 ? polygon(g.outline) : dot(g.center, 14)
                ctx.fill(shape, with: .color(.green))
            }
            var line = Path()
            if let first = hole.playingLine.first {
                line.move(to: p(first))
                hole.playingLine.dropFirst().forEach { line.addLine(to: p($0)) }
            }
            ctx.stroke(line, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
            for t in hole.tees { ctx.fill(dot(t.coordinate, 7), with: .color(.white)) }
            if let pin = hole.target {
                let q = p(pin)
                var flag = Path()
                flag.move(to: q)
                flag.addLine(to: CGPoint(x: q.x, y: q.y - 28))
                ctx.stroke(flag, with: .color(.white), lineWidth: 3)
                ctx.fill(Path(CGRect(x: q.x, y: q.y - 28, width: 16, height: 10)), with: .color(.red))
            }
            if let landing {
                let c = landing.target.coordinate
                let r = CGFloat(landing.searchRadiusMeters * scale)
                let q = p(c)
                ctx.stroke(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(.orange), lineWidth: 3)
            }
            if let golfer { ctx.fill(dot(golfer, 9), with: .color(.yellow)) }
        }
    }
}

// MARK: - Club picker & bag

/// Club in hand. Pre-selected from the recommendation during a round; choosing by hand overrides it for this shot.
struct ClubPicker: View {
    @Environment(AppModel.self) private var model
    @State private var editingBag = false

    var body: some View {
        HStack {
            Picker("Club", selection: Binding(
                get: { model.bagClub },
                set: { model.bagClub = $0; model.clubOverridden = true })) {
                Text("Automatic").tag(BagClub?.none)
                ForEach(model.round.bag.playable) { s in
                    Text(s.club.name).tag(BagClub?.some(s.club))
                }
            }
            .pickerStyle(.menu)
            .font(.title2)
            .tint(Palette.accent)
            .accessibilityLabel("Club: \(model.bagClub?.name ?? "Automatic")")
            Button("My bag") { editingBag = true }
                .font(.headline)
        }
        .sheet(isPresented: $editingBag) { ClubBagView() }
    }
}

struct ClubBagView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.round.bag.stats) { s in
                        ClubRow(stats: s)
                    }
                } footer: {
                    Text("Carries are learned from your tracked shots after \(ClubStats.minimumSamples) shots with a club. A distance you enter yourself always wins.")
                }
            }
            .navigationTitle("My bag")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct ClubRow: View {
    @Environment(AppModel.self) private var model
    let stats: ClubStats

    var body: some View {
        let yards = Int(Units.yards(fromMeters: stats.effectiveCarryMeters).rounded())
        VStack(alignment: .leading, spacing: 6) {
            Toggle(stats.club.name, isOn: Binding(
                get: { stats.isInBag },
                set: { v in model.round.bag.update(stats.club) { $0.isInBag = v } }))
                .font(.title3.bold())
            if stats.isInBag {
                Stepper("Carry \(yards) yards\(stats.isLearned ? " (learned)" : "")",
                        onIncrement: { set(yards + 1) }, onDecrement: { set(yards - 1) })
                if stats.userCarryMeters != nil {
                    Button("Use learned distance") { model.round.bag.update(stats.club) { $0.userCarryMeters = nil } }
                }
            }
        }
    }

    private func set(_ yards: Int) {
        model.round.bag.update(stats.club) { $0.userCarryMeters = Units.meters(fromYards: Double(max(10, yards))) }
    }
}
