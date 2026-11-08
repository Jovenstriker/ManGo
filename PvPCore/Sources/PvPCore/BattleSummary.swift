import Foundation

/// A finished battle as ManGo followed it, for a timeline like PvPoke's: both sides' fast moves,
/// charged moves, shields, switches and faints, on the clock of play. Charged moves take no time
/// on that clock, so each stop is an instant and its charged moves are drawn there in order.
/// Times are seconds of play from the start of the battle.
public struct BattleSummary: Codable, Sendable, Hashable, Identifiable {
    public enum Side: String, Codable, Sendable, Hashable { case you, them }

    /// From `start` for `turns` turns, cut at `end` when a charged move came first (the one in
    /// progress at your charged move, which counts).
    public struct FastMove: Codable, Sendable, Hashable {
        public var side: Side
        public var start: Double
        public var end: Double
        public var turns: Int
        public var type: String?
        /// Yours are filled in from your fast move's length, not each one seen.
        public var estimated: Bool
    }

    public struct ChargedMove: Codable, Sendable, Hashable {
        public var side: Side
        public var time: Double
        public var name: String?
        public var type: String?
        public var pokemon: String?
        /// The other side blocked it with a Protect Shield.
        public var shielded: Bool
        /// The opponent's energy before and after: theirs as they threw, or theirs at yours.
        public var energyBefore: Int?
        public var energyAfter: Int?
    }

    public struct Marker: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable, Hashable { case switched, fainted }
        public var side: Side
        public var time: Double
        public var kind: Kind
        /// Who came in (a switch) or went down (a faint), if known.
        public var pokemon: String?
    }

    public var id = UUID()
    public var date = Date()
    /// "won", "lost" or "draw"; nil if ManGo didn't see the results screen.
    public var result: String?
    public var opponentTeam: [String]
    public var yourTeam: [String]
    public var duration: Double
    public var fastMoves: [FastMove]
    public var chargedMoves: [ChargedMove]
    public var markers: [Marker]
}

/// What happened in the battle so far, kept by `BattleAutomation`; their fast moves come from
/// the tracker's history when it ends, after every correction to them.
struct BattleSummaryRecord {
    /// Battle time play began, and of each stop since (its final value: the freeze can move
    /// later while it's stopped).
    var start: Double?
    var stops: [Double] = []
    /// Your fast move from each time your buttons changed (your lead, then each switch), and
    /// whether that switch was made in play, so it took a turn.
    var yourMoves: [(from: Double, turns: Int, type: String?, switchTurn: Bool)] = []
    var charged: [(stop: Int, move: BattleSummary.ChargedMove)] = []
    var markers: [(stop: Int?, marker: BattleSummary.Marker)] = []
    var yourTeam: [String] = []

    var isEmpty: Bool { charged.isEmpty && stops.count < 2 }

    func summary(tracker: OpponentTracker, endedAt end: Double, result: String?) -> BattleSummary? {
        guard let origin = start, !isEmpty else { return nil }
        let stopTimes = stops + [end]
        func at(_ stop: Int?) -> Double? { stop.flatMap { stopTimes.indices.contains($0) ? stopTimes[$0] : nil } }
        var fast: [BattleSummary.FastMove] = []
        // Theirs, as counted: whole fast moves in each stretch, and the one in progress at your
        // charged move (cut where the battle froze).
        for p in tracker.team {
            guard let move = p.fastMove else { continue }
            let d = Double(move.turns) * turnDuration
            for s in p.history where s.length > 0 || s.interrupted {
                let whole = Int((s.length / d + 1e-9).rounded(.down))
                for j in 0..<whole {
                    fast.append(.init(side: .them, start: s.start + Double(j) * d - origin, end: s.start + Double(j + 1) * d - origin,
                                      turns: move.turns, type: move.type, estimated: false))
                }
                if s.interrupted {
                    let from = s.start + Double(whole) * d
                    fast.append(.init(side: .them, start: from - origin, end: max(from, s.start + s.length) - origin,
                                      turns: move.turns, type: move.type, estimated: false))
                }
            }
        }
        // Yours, filled in: back to back from each restart to the next stop, each Pokémon from
        // when it came in (a turn later for a switch made in play).
        var from = origin
        for to in stopTimes {
            defer { from = to }
            guard to > from + 0.05 else { continue }
            for (i, move) in yourMoves.enumerated() {
                let until = min(to, i + 1 < yourMoves.count ? yourMoves[i + 1].from : .infinity)
                var t = move.from > from ? move.from + (move.switchTurn ? turnDuration : 0) : from
                let d = Double(move.turns) * turnDuration
                while t < until - 0.05 {
                    fast.append(.init(side: .you, start: t - origin, end: min(t + d, until) - origin, turns: move.turns, type: move.type, estimated: true))
                    t += d
                }
            }
        }
        let charged = self.charged.compactMap { c -> BattleSummary.ChargedMove? in
            guard let t = at(c.stop) else { return nil }
            var m = c.move
            m.time = t - origin
            return m
        }
        var markers = self.markers.map { m -> BattleSummary.Marker in
            var marker = m.marker
            if let t = at(m.stop) { marker.time = t }
            marker.time -= origin
            return marker
        }
        // The last knockout ended it.
        if result == "won" {
            markers.append(.init(side: .them, time: end - origin, kind: .fainted,
                                 pokemon: tracker.active.map { tracker.data.species[$0.speciesId]?.speciesName ?? $0.speciesId }))
        } else if result == "lost" {
            markers.append(.init(side: .you, time: end - origin, kind: .fainted))
        }
        return BattleSummary(
            result: result,
            opponentTeam: tracker.team.map { tracker.data.species[$0.speciesId]?.speciesName ?? $0.speciesId },
            yourTeam: yourTeam,
            duration: max(0, end - origin),
            fastMoves: fast.sorted { $0.start < $1.start },
            chargedMoves: charged,
            markers: markers.sorted { $0.time < $1.time })
    }
}
