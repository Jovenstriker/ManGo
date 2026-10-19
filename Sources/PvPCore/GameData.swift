import Foundation

/// A move as PvPoke describes it. `energy` is the cost of a charged move;
/// `energyGain` is what a fast move generates. `turns` is the fast move's length
/// in 0.5s PvP turns.
public struct Move: Codable, Hashable, Sendable, Identifiable {
    public let moveId: String
    public let name: String
    public let type: String
    public let energy: Int
    public let energyGain: Int
    public let turns: Int

    public var id: String { moveId }
    public var isFast: Bool { energyGain > 0 }

    public init(moveId: String, name: String, type: String, energy: Int, energyGain: Int, turns: Int) {
        self.moveId = moveId
        self.name = name
        self.type = type
        self.energy = energy
        self.energyGain = energyGain
        self.turns = turns
    }
}

public struct Species: Codable, Hashable, Sendable, Identifiable {
    public let speciesId: String
    public let speciesName: String
    public let fastMoves: [String]
    public let chargedMoves: [String]
    /// PvPoke's recommended moveset: [fast, charged1, charged2]. Empty if unranked.
    public var recommendedMoveset: [String] = []

    public var id: String { speciesId }

    private enum CodingKeys: String, CodingKey {
        case speciesId, speciesName, fastMoves, chargedMoves
    }
}

/// PvPoke game data: every species and move, plus a league's ranking movesets.
///
/// Load it from PvPoke's `src/data/gamemaster.json` and
/// `src/data/rankings/all/overall/rankings-<cp>.json`.
public struct GameData: Sendable {
    public let species: [String: Species]
    public let moves: [String: Move]

    public init(species: [Species], moves: [Move]) {
        self.species = Dictionary(species.map { ($0.speciesId, $0) }, uniquingKeysWith: { a, _ in a })
        self.moves = Dictionary(moves.map { ($0.moveId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public init(gamemasterJSON: Data, rankingsJSON: Data? = nil) throws {
        struct Gamemaster: Decodable {
            let pokemon: [Species]
            let moves: [Move]
        }
        struct Ranking: Decodable {
            let speciesId: String
            let moveset: [String]
        }

        let gm = try JSONDecoder().decode(Gamemaster.self, from: gamemasterJSON)
        var species = gm.pokemon
        if let rankingsJSON {
            let rankings = try JSONDecoder().decode([Ranking].self, from: rankingsJSON)
            let movesets = Dictionary(rankings.map { ($0.speciesId, $0.moveset) }, uniquingKeysWith: { a, _ in a })
            for i in species.indices {
                species[i].recommendedMoveset = movesets[species[i].speciesId] ?? []
            }
        }
        self.init(species: species, moves: gm.moves)
    }

    public func fastMoves(for speciesId: String) -> [Move] {
        species[speciesId]?.fastMoves.compactMap { moves[$0] } ?? []
    }

    /// Charged moves for a species, PvPoke's recommended ones first.
    public func chargedMoves(for speciesId: String) -> [Move] {
        guard let s = species[speciesId] else { return [] }
        let recommended = Set(s.recommendedMoveset.dropFirst())
        let ordered = s.chargedMoves.filter { recommended.contains($0) } + s.chargedMoves.filter { !recommended.contains($0) }
        return ordered.compactMap { moves[$0] }
    }

    /// Species whose name matches `query`, ranked species first.
    public func search(_ query: String, limit: Int = 20) -> [Species] {
        let q = query.lowercased()
        return species.values
            .filter { q.isEmpty || $0.speciesName.lowercased().contains(q) }
            .sorted { a, b in
                let aPrefix = a.speciesName.lowercased().hasPrefix(q), bPrefix = b.speciesName.lowercased().hasPrefix(q)
                if aPrefix != bPrefix { return aPrefix }
                if a.recommendedMoveset.isEmpty != b.recommendedMoveset.isEmpty { return !a.recommendedMoveset.isEmpty }
                return a.speciesName < b.speciesName
            }
            .prefix(limit)
            .map { $0 }
    }
}
