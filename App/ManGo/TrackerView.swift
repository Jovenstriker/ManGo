import PhotosUI
import PvPCore
import SwiftUI

struct TrackerView: View {
    @Bindable var model: TrackerModel
    @State private var pickingSpecies = false
    @State private var screenshot: PhotosPickerItem?
    @State private var screenshotResult: String?
    @State private var overlay = OverlayController()

    var body: some View {
        NavigationStack {
            Group {
                if let error = model.loadError {
                    ContentUnavailableView("No PvPoke data", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    // Energy is derived from the clock, so redraw every tenth of a second.
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        if let snap = model.snapshot(at: context.date) {
                            content(snap)
                        }
                    }
                }
            }
            .navigationTitle("Opponent Energy")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Starts screen recording with ManGo's screen reader.
                    BroadcastPickerButton().frame(width: 44, height: 44)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("New battle", systemImage: "arrow.counterclockwise") { model.newBattle() }
                        PhotosPicker(selection: $screenshot, matching: .screenshots) {
                            Label("Test with screenshot", systemImage: "text.viewfinder")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onChange(of: screenshot) { _, item in
                guard let item else { return }
                screenshot = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data)?.cgImage
                    else { return }
                    screenshotResult = await model.testScreenshot(image)
                }
            }
            .alert("Screenshot", isPresented: Binding(get: { screenshotResult != nil }, set: { if !$0 { screenshotResult = nil } })) {
                Button("OK") {}
            } message: {
                Text(screenshotResult ?? "")
            }
            .task { overlay.attach(model) }
            .sheet(isPresented: $pickingSpecies) {
                if let data = model.data {
                    SpeciesPicker(data: data) { model.setActive($0.speciesId) }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ snap: OpponentTracker.Snapshot) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                overlaySection
                teamRow(active: snap.pokemon)
                screenReaderStatus(context: snap)

                if snap.awaitingOpponent {
                    ContentUnavailableView(
                        "Their Pokémon fainted",
                        systemImage: "pause.circle",
                        description: Text("Pick their next Pokémon when it comes out. Counting resumes then.")
                    )
                } else if let p = snap.pokemon {
                    energyGauge(snap)
                    pvpokeMoveset(p.speciesId)
                    fastMoveSection(p, turnInto: snap.turnIntoFastMove)
                    chargedMoveSection(snap)
                    chargedMoveControl(snap.isPaused)
                } else {
                    ContentUnavailableView(
                        "Pick the opponent's lead",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Then tap their fast move the moment you see it.")
                    )
                }
            }
            .padding()
        }
    }

    // MARK: Sections

    /// The PiP card. It pops out over Pokémon GO automatically when you leave the app.
    private var overlaySection: some View {
        VStack(spacing: 6) {
            OverlayPreview(layer: overlay.displayLayer)
                .aspectRatio(OverlayController.size.width / OverlayController.size.height, contentMode: .fit)
                .frame(maxWidth: 260)
            if overlay.isSupported {
                Button(overlay.isActive ? "Close overlay" : "Pop out overlay",
                       systemImage: "pip.enter") { overlay.toggle() }
                    .font(.caption)
            } else {
                Text("Picture-in-Picture isn't available on this device").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func teamRow(active: OpponentTracker.Pokemon?) -> some View {
        HStack {
            ForEach(model.tracker?.team ?? [], id: \.speciesId) { p in
                let isActive = p.speciesId == active?.speciesId
                // Benched Pokémon show the energy they'll come back in with.
                Button(isActive || p.isFainted ? name(p.speciesId) : "\(name(p.speciesId)) · \(p.bankedEnergy)") {
                    model.setActive(p.speciesId)
                }
                    .buttonStyle(.bordered)
                    .tint(isActive ? .accentColor : .secondary)
                    .strikethrough(p.isFainted)
                    .disabled(isActive || p.isFainted)
            }
            if (model.tracker?.team.count ?? 0) < 3 {
                Button("Add", systemImage: "plus") { pickingSpecies = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func screenReaderStatus(context snap: OpponentTracker.Snapshot) -> some View {
        let forms = model.formOptions
        HStack {
            if let at = model.lastReadAt, Date.now.timeIntervalSince(at) < 3 {
                Label(model.lastReadName.map { "Reading screen · \($0)" } ?? "Reading screen…", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.green)
            }
            Spacer()
            if forms.count > 1, let active = snap.pokemon {
                Menu {
                    ForEach(forms) { form in
                        Button(form.speciesName) { model.changeForm(form.speciesId) }
                            .disabled(form.speciesId == active.speciesId)
                    }
                } label: {
                    Label("Form", systemImage: "arrow.triangle.swap").font(.caption)
                }
            }
        }
    }

    private func energyGauge(_ snap: OpponentTracker.Snapshot) -> some View {
        VStack(spacing: 6) {
            Text("\(snap.energy)")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            ProgressView(value: Double(snap.energy), total: Double(maxEnergy))
            if snap.isPaused {
                Text("Paused").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// PvPoke's recommended moveset for Great League, with each move's energy.
    @ViewBuilder
    private func pvpokeMoveset(_ speciesId: String) -> some View {
        if let rec = model.data?.recommendedMoves(for: speciesId), let fast = rec.fast {
            VStack(alignment: .leading, spacing: 8) {
                Label("PvPoke recommended", systemImage: "star.fill")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    moveStat(fast.name, detail: "+\(fast.energyGain) / \(fast.turns)T")
                    ForEach(rec.charged) { move in
                        Divider()
                        moveStat(move.name, detail: "\(move.energy) energy")
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func moveStat(_ name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func fastMoveSection(_ p: OpponentTracker.Pokemon, turnInto: Int?) -> some View {
        let options = model.data?.fastMoves(for: p.speciesId) ?? []
        let recommended = model.data?.species[p.speciesId]?.recommendedMoveset.first
        VStack(alignment: .leading, spacing: 8) {
            Text(p.fastMove == nil ? "Tap their fast move when you see it" : "Fast move · tap when you see it to correct")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(options) { move in
                Button {
                    model.sawFastMove(move.moveId)
                } label: {
                    HStack {
                        Text(move.name).bold()
                        if move.moveId == recommended { Image(systemName: "star.fill").font(.caption) }
                        Spacer()
                        Text("+\(move.energyGain) / \(move.turns)T").monospacedDigit()
                        if move == p.fastMove, let turnInto {
                            turnDots(total: move.turns, current: turnInto)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(move == p.fastMove ? .accentColor : .secondary)
            }
        }
    }

    private func turnDots(total: Int, current: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { i in
                Circle().frame(width: 6, height: 6).opacity(i <= current ? 1 : 0.25)
            }
        }
    }

    private func chargedMoveSection(_ snap: OpponentTracker.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Their charged moves · tap when they throw one").font(.caption).foregroundStyle(.secondary)
            ForEach(snap.chargedMoves) { status in
                Button {
                    model.opponentThrewChargedMove(status.move.moveId)
                } label: {
                    HStack {
                        Text(status.move.name).bold()
                        if status.isRevealed {
                            Image(systemName: "eye.fill").font(.caption)
                        } else if status.isRecommended {
                            Image(systemName: "star.fill").font(.caption)
                        }
                        Text("\(status.move.energy)").foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Text(readiness(status)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(status.ready ? .red : .secondary)
                .opacity(status.isRevealed || status.isRecommended ? 1 : 0.6)
            }
        }
        .disabled(snap.isPaused)
    }

    /// While a charged move plays out or a fainted Pokémon is replaced, counting is
    /// stopped until the battle resumes.
    private func chargedMoveControl(_ isPaused: Bool) -> some View {
        VStack(spacing: 8) {
            if isPaused {
                Button { model.resume() } label: {
                    Label("Battle resumed", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            } else {
                Button { model.playerThrewChargedMove() } label: {
                    Label("I threw a charged move", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                HStack {
                    Button { model.playerFainted() } label: {
                        Text("Mine fainted").frame(maxWidth: .infinity)
                    }
                    Button {
                        model.opponentFainted()
                        if (model.tracker?.team.count ?? 0) < 3 { pickingSpecies = true }
                    } label: {
                        Text("Theirs fainted").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .controlSize(.large)
    }

    // MARK: Helpers

    private func readiness(_ s: OpponentTracker.ChargedMoveStatus) -> String {
        if s.ready { return "READY" }
        guard let turns = s.turnsUntilReady else { return "?" }
        return "\(s.fastMovesNeeded) fast · \(turns)T"
    }

    private func name(_ speciesId: String) -> String {
        model.data?.species[speciesId]?.speciesName ?? speciesId
    }
}
