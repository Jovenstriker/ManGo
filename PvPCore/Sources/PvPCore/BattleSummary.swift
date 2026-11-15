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
        /// Who used it (PvPoke species id), the move's PvPoke id and the energy it gives.
        public var pokemon: String? = nil
        public var moveId: String? = nil
        public var energy: Int? = nil
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
        /// The move's PvPoke id and energy cost, and who threw it (PvPoke species id).
        public var moveId: String? = nil
        public var cost: Int? = nil
        public var speciesId: String? = nil
        /// Blocked by Mimikyu's Disguise, the first charged move it takes, not a Protect Shield.
        public var disguise: Bool? = nil
    }

    public struct Marker: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable, Hashable { case switched, fainted }
        public var side: Side
        public var time: Double
        public var kind: Kind
        /// Who came in (a switch) or went down (a faint), if known.
        public var pokemon: String?
        /// A switch: who went out. A faint of theirs: who they sent in next.
        public var other: String? = nil
        /// Theirs: the energy the one going out had, which it keeps on the bench.
        public var energyOut: Int? = nil
        /// Theirs: the energy the one coming in brought back, if it had been in before.
        public var energyIn: Int? = nil
        /// The turns the switch took: 0 in a stop or right after a charged move, else 1.
        public var turns: Int? = nil
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
    /// Your Pokémon in the order they came in (PvPoke species ids), each with the charged moves
    /// on its buttons.
    public var yourPokemon: [YourPokemon]? = nil
    /// When each stop came on the clock of play, and the read time (the recording's time, for a
    /// recorded battle) play began and restarted after each: for finding a moment in the video.
    public var stops: [Double]? = nil
    public var readTimes: [Double]? = nil

    public struct YourPokemon: Codable, Sendable, Hashable {
        public var speciesId: String
        public var fastMove: String?
        public var chargedMoves: [String]
    }

    /// The read time at `time` on the clock of play; a charged move's stop gives the freeze.
    public func readTime(at time: Double) -> Double? {
        guard let reads = readTimes, let stops, reads.count == stops.count + 1 else { return nil }
        let starts = [0] + stops
        let k = starts.lastIndex { $0 < time } ?? 0
        return reads[k] + (time - starts[k])
    }

    /// The other way: the time of play at read time `read`, and whether a stop had it frozen.
    /// Nil before play began.
    public func playTime(atRead read: Double) -> (time: Double, stopped: Bool)? {
        guard let reads = readTimes, let stops, reads.count == stops.count + 1, let first = reads.first, read >= first else { return nil }
        let starts = [0] + stops
        let k = reads.lastIndex { $0 <= read } ?? 0
        let t = starts[k] + (read - reads[k])
        if k + 1 < starts.count, t >= starts[k + 1] { return (starts[k + 1], true) }
        return (t, false)
    }
}

/// What happened in the battle so far, kept by `BattleAutomation`; their fast moves come from
/// the tracker's history when it ends, after every correction to them.
struct BattleSummaryRecord {
    /// Battle time play began, and of each stop since (its final value: the freeze can move
    /// later while it's stopped).
    var start: Double?
    var stops: [Double] = []
    /// The read time play began, and of each restart after a stop.
    var readTimes: [Double] = []
    /// Your fast move from each time your buttons changed (your lead, then each switch), and
    /// whether that switch was made in play, so it took a turn.
    var yourMoves: [YourMove] = []
    struct YourMove {
        var from: Double
        var turns: Int
        var type: String?
        var switchTurn: Bool
        /// PvPoke's fast move for the best-ranked of `species`, the Pokémon (best first) that
        /// learn both `charged`, the charged moves on your buttons.
        var moveId: String? = nil
        var species: [String] = []
        var charged: [String] = []
        /// `turns` was measured from your fast moves landing.
        var measured = false
    }
    var charged: [(stop: Int, move: BattleSummary.ChargedMove)] = []
    var markers: [(stop: Int?, marker: BattleSummary.Marker)] = []
    var yourTeam: [String] = []

    var isEmpty: Bool { charged.isEmpty && stops.count < 2 }


    func summary(tracker: OpponentTracker, endedAt end: Double, result: String?) -> BattleSummary? {
        guard let origin = start, !isEmpty else { return nil }
        let data = tracker.data
        func name(_ id: String?) -> String? { id.map { data.species[$0]?.speciesName ?? $0 } }
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
                                      turns: move.turns, type: move.type, estimated: false,
                                      pokemon: p.speciesId, moveId: move.moveId, energy: move.energyGain))
                }
                if s.interrupted {
                    let from = s.start + Double(whole) * d
                    fast.append(.init(side: .them, start: from - origin, end: max(from, s.start + s.length) - origin,
                                      turns: move.turns, type: move.type, estimated: false,
                                      pokemon: p.speciesId, moveId: move.moveId, energy: move.energyGain))
                }
            }
        }
        // A banner read cut short names part of yours ("ken" for Blaziken): it's the whole name.
        func full(_ name: String?) -> String? {
            name.map { n in yourTeam.first { $0.count > n.count && $0.localizedCaseInsensitiveContains(n) } ?? n }
        }
        var team: [String] = []
        for n in yourTeam.compactMap(full) where !team.contains(n) { team.append(n) }

        // Which of yours each was: of the Pokémon that learn both charged moves on its buttons,
        // one your banners named, else PvPoke's best-ranked. Its fast move is PvPoke's for it, or
        // its move of the length your fast moves landing showed.
        func baseName(_ id: String?) -> String? {
            id.flatMap { data.species[$0] }.map { NameMatcher.normalize($0.speciesName.split(separator: "(").first.map(String.init) ?? $0.speciesName) }
        }
        let named = Set(team.map(NameMatcher.normalize))
        let yours = yourMoves.map { m -> (move: YourMove, speciesId: String?, fast: Move?, turns: Int) in
            let id = m.species.first { baseName($0).map(named.contains) == true } ?? m.species.first
            var move = id.flatMap { data.recommendedMoves(for: $0).fast } ?? m.moveId.flatMap { data.moves[$0] }
            if m.measured, move?.turns != m.turns, let id, let other = data.fastMoves(for: id).first(where: { $0.turns == m.turns }) {
                move = other
            }
            return (m, id, move, m.measured ? m.turns : move?.turns ?? m.turns)
        }
        // Yours, filled in: back to back from each restart to the next stop, each Pokémon from
        // when it came in (a turn later for a switch made in play).
        var from = origin
        for to in stopTimes {
            defer { from = to }
            guard to > from + 0.05 else { continue }
            for (i, y) in yours.enumerated() {
                let until = min(to, i + 1 < yours.count ? yours[i + 1].move.from : .infinity)
                var t = y.move.from > from ? y.move.from + (y.move.switchTurn ? turnDuration : 0) : from
                let d = Double(y.turns) * turnDuration
                while t < until - 0.05 {
                    fast.append(.init(side: .you, start: t - origin, end: min(t + d, until) - origin, turns: y.turns,
                                      type: y.fast?.type ?? y.move.type, estimated: true,
                                      pokemon: y.speciesId, moveId: y.fast?.moveId, energy: y.fast?.energyGain))
                    t += d
                }
            }
        }
        var yourPokemon: [BattleSummary.YourPokemon] = []
        for y in yours {
            guard let id = y.speciesId, !yourPokemon.contains(where: { $0.speciesId == id }) else { continue }
            yourPokemon.append(.init(speciesId: id, fastMove: y.fast?.moveId, chargedMoves: y.move.charged))
        }
        let cameIn = yours.map { $0.move.from - origin }

        var charged = self.charged.compactMap { c -> BattleSummary.ChargedMove? in
            guard let t = at(c.stop) else { return nil }
            var m = c.move
            m.time = t - origin
            if m.side == .you {
                m.pokemon = full(m.pokemon)
                // The one your banner named, else the one in before the stop.
                let banner = m.pokemon.map(NameMatcher.normalize)
                let i = yours.indices.last { banner != nil && baseName(yours[$0].speciesId) == banner && cameIn[$0] <= m.time + 0.01 }
                    ?? yours.indices.last { cameIn[$0] < m.time - 0.01 } ?? yours.indices.first
                m.speciesId = i.flatMap { yours[$0].speciesId }
            }
            return m
        }
        // The first charged move a Mimikyu takes is blocked by its Disguise, "BLOCKED!" like a
        // shield but not one (171449: yours blocked Turtonator's Brutal Swing after "No Protect
        // Shields remaining!"; 142007: theirs your first Energy Ball, a shield your second).
        var disguised: Set<String> = []
        for k in charged.indices {
            let t = charged[k].time
            let target = charged[k].side == .them
                ? yours.indices.last { cameIn[$0] <= t + 0.01 }.flatMap { yours[$0].speciesId }
                : fast.filter { $0.side == .them && $0.start <= t + 0.01 }.max { $0.start < $1.start }?.pokemon
            guard let target, baseName(target) == "mimikyu", disguised.insert("\(charged[k].side)\(target)").inserted else { continue }
            if charged[k].shielded { charged[k].disguise = true }
        }
        // Two Protect Shields a side: a "BLOCKED!" after both were used isn't one.
        var shieldsUsed: [BattleSummary.Side: Int] = [:]
        for k in charged.indices where charged[k].shielded && charged[k].disguise != true {
            let blocker: BattleSummary.Side = charged[k].side == .you ? .them : .you
            shieldsUsed[blocker, default: 0] += 1
            if shieldsUsed[blocker]! > 2 { charged[k].shielded = false }
        }
        var markers = self.markers.map { m -> BattleSummary.Marker in
            var marker = m.marker
            if let t = at(m.stop) { marker.time = t }
            marker.time -= origin
            return marker
        }
        // The last knockout ended it.
        if result == "won" {
            markers.append(.init(side: .them, time: end - origin, kind: .fainted, pokemon: name(tracker.active?.speciesId)))
        } else if result == "lost" {
            markers.append(.init(side: .you, time: end - origin, kind: .fainted))
        }
        // Yours by who was in: the next to come in after a switch; the one in before a faint.
        for k in markers.indices where markers[k].side == .you {
            let t = markers[k].time
            switch markers[k].kind {
            case .switched:
                if let i = cameIn.indices.dropFirst().first(where: { cameIn[$0] >= t - 1 }) {
                    markers[k].pokemon = name(yours[i].speciesId)
                    markers[k].other = name(yours[i - 1].speciesId)
                }
            case .fainted:
                let next = cameIn.indices.dropFirst().first { cameIn[$0] >= t - 0.01 }
                let down = next.map { $0 - 1 } ?? cameIn.indices.last
                markers[k].pokemon = down.flatMap { name(yours[$0].speciesId) }
                markers[k].other = next.flatMap { name(yours[$0].speciesId) }
            }
        }
        return BattleSummary(
            result: result,
            opponentTeam: tracker.team.map { name($0.speciesId) ?? $0.speciesId },
            yourTeam: team,
            duration: max(0, end - origin),
            fastMoves: fast.sorted { $0.start < $1.start },
            chargedMoves: charged,
            markers: markers.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element),
            yourPokemon: yourPokemon,
            stops: stops.map { $0 - origin },
            readTimes: readTimes.count == stops.count + 1 ? readTimes : nil)
    }
}
