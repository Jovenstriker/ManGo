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
    /// 1-based PvPoke ranking. `nil` if unranked.
    public var rank: Int?

    public var id: String { speciesId }

    private enum CodingKeys: String, CodingKey {
        case speciesId, speciesName, fastMoves, chargedMoves
    }
}

/// PvPoke game data: species and moves, plus a league's ranks and movesets.
///
/// Load it from PvPoke's `src/data/gamemaster.json` and
/// `src/data/rankings/all/overall/rankings-1500.json`.
public struct GameData: Sendable {
    public let species: [String: Species]
    public let moves: [String: Move]

    public init(species: [Species], moves: [Move]) {
        self.species = Dictionary(species.map { ($0.speciesId, $0) }, uniquingKeysWith: { a, _ in a })
        self.moves = Dictionary(moves.map { ($0.moveId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// With `topRanked`, only the top N species in the rankings are kept.
    public init(gamemasterJSON: Data, rankingsJSON: Data? = nil, topRanked: Int? = nil) throws {
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
            var byId: [String: (rank: Int, moveset: [String])] = [:]
            for (i, r) in rankings.enumerated() where byId[r.speciesId] == nil {
                byId[r.speciesId] = (i + 1, r.moveset)
            }
            for i in species.indices {
                guard let r = byId[species[i].speciesId] else { continue }
                species[i].rank = r.rank
                species[i].recommendedMoveset = r.moveset
            }
            if let topRanked {
                species = species.filter { ($0.rank ?? .max) <= topRanked }
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

    /// PvPoke's recommended moveset as moves: the fast move and up to two charged moves.
    /// Moves outside the species' list (Return, Frustration) are left out.
    public func recommendedMoves(for speciesId: String) -> (fast: Move?, charged: [Move]) {
        guard let s = species[speciesId], let first = s.recommendedMoveset.first else { return (nil, []) }
        let charged = s.recommendedMoveset.dropFirst().filter { s.chargedMoves.contains($0) }
        return (s.fastMoves.contains(first) ? moves[first] : nil, charged.compactMap { moves[$0] })
    }

    /// Species whose name matches `query`: name-prefix matches first, then by rank.
    public func search(_ query: String, limit: Int = 20) -> [Species] {
        let q = query.lowercased()
        return species.values
            .filter { q.isEmpty || $0.speciesName.lowercased().contains(q) }
            .sorted { a, b in
                let aPrefix = a.speciesName.lowercased().hasPrefix(q), bPrefix = b.speciesName.lowercased().hasPrefix(q)
                if aPrefix != bPrefix { return aPrefix }
                if a.rank != b.rank { return (a.rank ?? .max) < (b.rank ?? .max) }
                return a.speciesName < b.speciesName
            }
            .prefix(limit)
            .map { $0 }
    }
}
