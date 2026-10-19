import PvPCore
import SwiftUI

struct SpeciesPicker: View {
    let data: GameData
    let onPick: (Species) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(data.search(query, limit: 40)) { species in
                Button {
                    onPick(species)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(species.speciesName).font(.body)
                            Spacer()
                            if let rank = species.rank {
                                Text("#\(rank)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        Text(movesetLabel(species)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: "Opponent's Pokémon")
            .navigationTitle("Opponent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// PvPoke's recommended moveset, with each charged move's energy cost.
    private func movesetLabel(_ s: Species) -> String {
        let rec = data.recommendedMoves(for: s.speciesId)
        let charged = rec.charged.map { "\($0.name) \($0.energy)" }
        return ([rec.fast?.name].compactMap { $0 } + charged).joined(separator: " · ")
    }
}
