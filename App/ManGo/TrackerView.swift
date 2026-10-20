import PvPCore
import SwiftUI

/// Display only: everything is driven by the screen reader, so there's nothing to tap
/// mid-battle. The only controls start the screen reader and pop out the overlay.
struct TrackerView: View {
    let model: TrackerModel
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
            }
            .task { overlay.attach(model) }
        }
    }

    @ViewBuilder
    private func content(_ snap: OpponentTracker.Snapshot) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                overlaySection
                screenReaderStatus

                if let p = snap.pokemon {
                    teamRow(active: p)
                    energyGauge(snap)
                    pvpokeMoveset(p.speciesId)
                    chargedMoveList(snap)
                } else {
                    ContentUnavailableView(
                        "Waiting for a battle",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Tap the record button, start ManGo Screen Reader, then open Pokémon GO.")
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

    @ViewBuilder
    private var screenReaderStatus: some View {
        if let at = model.lastReadAt, Date.now.timeIntervalSince(at) < 3 {
            Label(model.lastEvent ?? "Reading screen…", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption).foregroundStyle(.green).lineLimit(1)
        }
    }

    /// The opponent's team. Benched Pokémon show the energy they'll come back in with.
    private func teamRow(active: OpponentTracker.Pokemon) -> some View {
        HStack {
            ForEach(model.tracker?.team ?? [], id: \.speciesId) { p in
                let isActive = p.speciesId == active.speciesId
                Text(isActive || p.isFainted ? name(p.speciesId) : "\(name(p.speciesId)) · \(p.bankedEnergy)")
                    .font(.subheadline.weight(isActive ? .bold : .regular))
                    .strikethrough(p.isFainted)
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(isActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1), in: Capsule())
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

    /// Every charged move they could have: ones they've used first, then PvPoke's picks.
    private func chargedMoveList(_ snap: OpponentTracker.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Their charged moves").font(.caption).foregroundStyle(.secondary)
            ForEach(snap.chargedMoves) { status in
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
                        .foregroundStyle(status.ready ? .red : .primary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(status.ready ? Color.red.opacity(0.12) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .opacity(status.isRevealed || status.isRecommended ? 1 : 0.6)
            }
        }
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
