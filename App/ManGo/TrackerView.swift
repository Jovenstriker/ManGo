import PvPCore
import SwiftUI

struct TrackerView: View {
    @Bindable var model: TrackerModel
    @State private var pickingSpecies = false

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
                ToolbarItem(placement: .primaryAction) {
                    Button("New battle", systemImage: "arrow.counterclockwise") { model.newBattle() }
                }
            }
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
                teamRow(active: snap.pokemon)

                if let p = snap.pokemon {
                    energyGauge(snap)
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

    private func teamRow(active: OpponentTracker.Pokemon?) -> some View {
        HStack {
            ForEach(model.tracker?.team ?? [], id: \.speciesId) { p in
                let isActive = p.speciesId == active?.speciesId
                Button(name(p.speciesId)) { model.setActive(p.speciesId) }
                    .buttonStyle(.bordered)
                    .tint(isActive ? .accentColor : .secondary)
                    .disabled(isActive)
            }
            if (model.tracker?.team.count ?? 0) < 3 {
                Button("Add", systemImage: "plus") { pickingSpecies = true }
                    .buttonStyle(.borderedProminent)
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

    @ViewBuilder
    private func fastMoveSection(_ p: OpponentTracker.Pokemon, turnInto: Int?) -> some View {
        let options = model.data?.fastMoves(for: p.speciesId) ?? []
        let recommended = model.data?.species[p.speciesId]?.recommendedMoveset.first
        VStack(alignment: .leading, spacing: 8) {
            Text(p.fastMove == nil ? "Tap their fast move when you see it" : "Fast move · tap to re-sync")
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

    /// While either side's charged move plays out, counting is stopped until the battle resumes.
    private func chargedMoveControl(_ isPaused: Bool) -> some View {
        Group {
            if isPaused {
                Button { model.resume() } label: {
                    Label("Battle resumed", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .tint(.green)
            } else {
                Button { model.playerThrewChargedMove() } label: {
                    Label("I threw a charged move", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                }
                .tint(.orange)
            }
        }
        .buttonStyle(.borderedProminent)
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
