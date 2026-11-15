import Foundation

/// A battle turn by turn as ManGo followed it, for comparing your play with a solver's: who was
/// in on each side, every Pokémon's energy at the end of each turn, the shields left, and what
/// each side did on it.
///
/// A turn is 0.5s of play; charged moves take none, so they come at the end of the turn before
/// the battle froze, after the fast moves that landed on it. A fast move lands on its last turn.
/// Their energy is ManGo's count as it ran (`Readings`). Yours is your fast move back to back from
/// each restart, as the timeline draws it, less the charged moves your banners named, and set
/// each turn by how full your charged move buttons were.
public enum TurnByTurn {
    /// What ManGo had after each read of a battle: their side's count, and your buttons' fill.
    public struct Readings: Sendable {
        public struct Count: Sendable {
            public var time: Double
            public var active: String?
            public var energy: [String: Int]
            public var fainted: Set<String>
        }
        public var counts: [Count] = []
        /// [time, left, right] on every frame.
        public var fills: [[Double]] = []

        public init() {}

        public mutating func add(_ read: ScreenRead, tracker: OpponentTracker) {
            let active = tracker.active?.speciesId
            var energy: [String: Int] = [:]
            for p in tracker.team { energy[p.speciesId] = p.speciesId == active ? tracker.snapshot(at: read.time).energy : p.bankedEnergy }
            counts.append(.init(time: read.time, active: active, energy: energy, fainted: Set(tracker.team.filter(\.isFainted).map(\.speciesId))))
            fills += (read.fillTrace ?? []).filter { $0.count == 3 }
        }
    }

    public struct Battle {
        public var battle: [String: String]
        public var turns: [[String: String]]
        /// Where your modelled energy came up short at a throw, for checking the model.
        public var notes: [String]
    }

    public static let battleColumns: [String] = ["battle_id", "recording", "battle_number", "video", "result",
                                                 "turns", "play_seconds", "video_start", "video_end"]
        + slots("you", ["", "_fast", "_charged"]) + slots("them", ["", "_fast", "_charged"])
        + ["you_charged_moves", "them_charged_moves", "you_shields_used", "them_shields_used", "you_switches", "them_switches"]

    public static let turnColumns: [String] = ["battle_id", "result", "turn", "play_seconds", "video_seconds", "you_active"]
        + slots("you", ["", "_energy"]) + ["you_shields", "you_action", "them_active"]
        + slots("them", ["", "_energy"]) + ["them_shields", "them_action", "charged_first"]

    private static func slots(_ side: String, _ fields: [String]) -> [String] {
        (1...3).flatMap { i in fields.map { "\(side)_\(i)\($0)" } }
    }

    private enum Event {
        case fast(BattleSummary.FastMove)
        case charged(BattleSummary.ChargedMove)
        case marker(BattleSummary.Marker)
    }

    /// The buttons read about a pixel row low: Jumpluff's Acrobatics (45) at 0.167, 0.367, 0.567
    /// after 1, 2 and 3 Fairy Winds (9 each), not 0.2, 0.4, 0.6.
    static let fillOffset = 0.033
    /// The buttons fade in for about this long after they come back.
    static let fadeIn = 0.7

    /// Where one button says your energy could be. It fills to the move's cost; then a lighter
    /// bar fills it again from the cost to 100 (171449's Melmetal at 0:58.7: Dynamic Punch's 45
    /// at 0.37 and Double Iron Bash's 35 at 0.47, both 65). Reading full, the lighter bar was too
    /// low to see, or full itself. Empty can be hidden too, so it says nothing. `past` says which
    /// a part-full button is showing (nil: either): the two can read alike (142007's Blaziken at
    /// 3:42, Aura Sphere's 55 a quarter full and Blaze Kick's 35 half: 18, or 70 as lighter bars).
    static func energies(fill f: Double, cost: Int, past: Bool? = nil) -> [ClosedRange<Double>] {
        let c = Double(cost), slack = 3.0
        if f >= 0.97 { return [c...(c + (0.1 + fillOffset) * (100 - c) + slack), (100 - slack)...100] }
        guard f > 0.05 else { return [] }
        let level = f + fillOffset
        var ranges: [ClosedRange<Double>] = []
        if past != true, level * c < c + slack { ranges.append(max(0, level * c - slack)...(level * c + slack)) }
        let lighter = c + level * (100 - c)
        if past != false, lighter - slack <= 100 { ranges.append((lighter - slack)...min(100, lighter + slack)) }
        return ranges
    }

    /// Where both buttons agree your energy is.
    static func energies(left: Double, _ right: Double, costs: (left: Int, right: Int), past: (left: Bool, right: Bool)? = nil) -> [ClosedRange<Double>] {
        let a = energies(fill: left, cost: costs.left, past: past?.left), b = energies(fill: right, cost: costs.right, past: past?.right)
        return a.flatMap { x in b.compactMap { y in x.overlaps(y) ? max(x.lowerBound, y.lowerBound)...min(x.upperBound, y.upperBound) : nil } }
    }

    public static func model(_ s: BattleSummary, id: String, recording: String, number: Int, video: String?,
                             readings: Readings? = nil, data: GameData) -> Battle {
        let byName = Dictionary(data.species.values.map { ($0.speciesName, $0.speciesId) }, uniquingKeysWith: { a, _ in a })
        func speciesId(_ name: String?) -> String? { name.flatMap { byName[$0] } }
        var notes: [String] = []

        let theirTeam = s.opponentTeam.compactMap(speciesId)
        let yourTeam = s.yourPokemon?.map(\.speciesId) ?? []
        let stops = s.stops ?? s.chargedMoves.map(\.time)
        func atStop(_ t: Double) -> Bool { stops.contains { abs($0 - t) < 0.01 } || s.chargedMoves.contains { abs($0.time - t) < 0.01 } }
        // The last turn of play before `t`: a fast move landing, or a charged move's freeze.
        func endTurn(_ t: Double) -> Int { max(0, Int((t / turnDuration).rounded()) - 1) }
        func playTurn(_ t: Double) -> Int { max(0, Int((t / turnDuration + 1e-6).rounded(.down))) }
        let turnCount = max(1, Int((s.duration / turnDuration - 1e-6).rounded(.up)))
        /// The turn a read belongs to; nil before GO or after the battle.
        func turn(atRead w: Double) -> (turn: Int, stopped: Bool)? {
            guard let (t, stopped) = s.playTime(atRead: w), t <= s.duration + 0.25 else { return nil }
            return (stopped ? endTurn(t) : playTurn(t), stopped)
        }

        // Their side: ManGo's count at the end of each turn (the latest read of it, or of before it).
        var counted: [Readings.Count?] = Array(repeating: nil, count: turnCount)
        if let readings {
            var last: [Readings.Count?] = Array(repeating: nil, count: turnCount)
            for c in readings.counts { if let k = turn(atRead: c.time)?.turn, k < turnCount { last[k] = c } }
            var best: Readings.Count?
            for k in 0..<turnCount {
                if let c = last[k], c.time > (best?.time ?? -.infinity) { best = c }
                counted[k] = best
            }
        }

        // Your buttons: the last steady reading on each turn of play, away from a fade-in.
        let fadeStarts = (s.readTimes ?? []) + s.markers.filter { $0.side == .you }.compactMap { s.readTime(at: $0.time + 0.01) }
        var fill: [[Double]?] = Array(repeating: nil, count: turnCount)
        var fillsByPokemon: [String: [[Double]]] = [:]
        let yourMoves = s.fastMoves.filter { $0.side == .you }
        if let frames = readings?.fills.sorted(by: { $0[0] < $1[0] }), frames.count >= 3 {
            for i in 2..<frames.count {
                let w = frames[(i - 2)...i]
                guard (1...2).allSatisfy({ b in w.map { $0[b] }.max()! - w.map { $0[b] }.min()! <= 0.015 }) else { continue }
                let f = frames[i - 1]
                guard let (k, stopped) = turn(atRead: f[0]), !stopped, k < turnCount,
                      !fadeStarts.contains(where: { f[0] >= $0 && f[0] < $0 + fadeIn }) else { continue }
                fill[k] = f
                if let t = s.playTime(atRead: f[0])?.time, let p = yourMoves.first(where: { $0.start <= t && t <= $0.end })?.pokemon {
                    fillsByPokemon[p, default: []].append(f)
                }
            }
        }
        // Which button is which move: the way round the two buttons agree on more often.
        var buttonCosts: [String: (left: Int, right: Int)] = [:]
        for p in s.yourPokemon ?? [] {
            let costs = p.chargedMoves.compactMap { data.moves[$0]?.energy }
            guard costs.count == 2 else { continue }
            let frames = fillsByPokemon[p.speciesId] ?? []
            func agreeing(_ l: Int, _ r: Int) -> Int { frames.filter { !energies(left: $0[1], $0[2], costs: (l, r)).isEmpty }.count }
            buttonCosts[p.speciesId] = agreeing(costs[0], costs[1]) >= agreeing(costs[1], costs[0]) ? (costs[0], costs[1]) : (costs[1], costs[0])
        }
        let gains = Dictionary(yourMoves.compactMap { m in m.pokemon.map { ($0, m.energy ?? 0) } }, uniquingKeysWith: { a, _ in a })

        // What happened, turn by turn: fast moves landing first, then the rest in order.
        var events: [(turn: Int, order: Int, event: Event)] = []
        for f in s.fastMoves {
            let whole = f.end - f.start >= Double(f.turns) * turnDuration - 0.05
            if f.side == .you, !whole {
                // Yours cut short counts only if their charged move interrupted it: you can't throw
                // mid-move, and a switch waits for it too, so otherwise the filled-in timing was off.
                let atEnd = s.chargedMoves.filter { abs($0.time - f.end) < 0.01 }
                guard atEnd.first?.side == .them else { continue }
            }
            events.append((endTurn(f.end), events.count, .fast(f)))
        }
        let later = s.chargedMoves.map { ($0.time, Event.charged($0)) } + s.markers.map { ($0.time + 0.001, Event.marker($0)) }
        for (t, e) in later.enumerated().sorted(by: { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }).map(\.element) {
            var k = endTurn(t)
            if case .marker(let m) = e, !atStop(m.time) { k = playTurn(m.time) }
            events.append((k, 1_000_000 + events.count, e))
        }
        events.sort { ($0.turn, $0.order) < ($1.turn, $1.order) }

        var energy: [BattleSummary.Side: [String: Int]] = [.you: [:], .them: [:]]
        var fainted: [BattleSummary.Side: Set<String>] = [.you: [], .them: []]
        var active: [BattleSummary.Side: String] = [:]
        active[.them] = s.fastMoves.first { $0.side == .them }?.pokemon ?? theirTeam.first
        active[.you] = yourTeam.first
        var shields: [BattleSummary.Side: Int] = [.you: 2, .them: 2]
        var past: [String: (left: Bool, right: Bool)] = [:]
        var theirThrows: [(turn: Int, pokemon: String, before: Int)] = []
        var counts = (youCharged: 0, themCharged: 0, youSwitches: 0, themSwitches: 0)
        func other(_ side: BattleSummary.Side) -> BattleSummary.Side { side == .you ? .them : .you }
        func clock(_ t: Double) -> String { String(format: "%.1f", t) }

        var rows: [[String: String]] = []
        var next = 0
        for turn in 0..<turnCount {
            var actions: [BattleSummary.Side: [String]] = [.you: [], .them: []]
            var throwers: [BattleSummary.Side] = []
            while next < events.count, events[next].turn <= turn {
                defer { next += 1 }
                switch events[next].event {
                case .fast(let f):
                    guard let p = f.pokemon, !fainted[f.side]!.contains(p) else { continue }
                    energy[f.side]![p] = min(100, (energy[f.side]![p] ?? 0) + (f.energy ?? 0))
                    active[f.side] = p
                    actions[f.side]!.append("fast:\(f.moveId ?? "?")")
                case .charged(let c):
                    guard let p = c.speciesId ?? active[c.side] else { continue }
                    var before = energy[c.side]![p] ?? 0
                    if c.side == .them, let count = c.energyBefore {
                        // Fast moves ManGo counted by the throw that the turns don't show yet landed on it.
                        if let f = s.fastMoves.first(where: { $0.side == .them && $0.pokemon == p }), let g = f.energy, g > 0, count > before {
                            for _ in 0..<((count - before) / g) { actions[.them]!.append("fast:\(f.moveId ?? "?")") }
                        }
                        before = count
                        theirThrows.append((turn, p, count))
                    }
                    if c.side == .you, let cost = c.cost, before < cost {
                        notes.append("your \(p) at \(clock(c.time))s: modelled \(before), threw \(c.moveId ?? "?") for \(cost)")
                        before = cost
                    }
                    energy[c.side]![p] = c.side == .them ? c.energyAfter ?? max(0, before - (c.cost ?? 0)) : max(0, before - (c.cost ?? 0))
                    if c.side == .you, let costs = buttonCosts[p], let left = energy[.you]![p] {
                        past[p] = (left >= costs.left, left >= costs.right)
                    }
                    active[c.side] = p
                    actions[c.side]!.append("charged:\(c.moveId ?? c.name ?? "?")\(c.disguise == true ? "(disguise)" : c.shielded ? "(shielded)" : "")")
                    if c.disguise == true {
                        actions[other(c.side)]!.append("disguise")
                    } else if c.shielded {
                        shields[other(c.side)]! -= 1
                        actions[other(c.side)]!.append("shield")
                    }
                    throwers.append(c.side)
                    if c.side == .you { counts.youCharged += 1 } else { counts.themCharged += 1 }
                case .marker(let m):
                    switch m.kind {
                    case .switched:
                        let into = speciesId(m.pokemon)
                        if m.side == .them, let out = speciesId(m.other), let left = m.energyOut { energy[.them]![out] = left }
                        if let into { active[m.side] = into }
                        let cost = m.turns.map { $0 == 1 ? "(1 turn)" : "(\($0) turns)" } ?? ""
                        actions[m.side]!.append("switch:\(into ?? "?")\(cost)")
                        if m.side == .you { counts.youSwitches += 1 } else { counts.themSwitches += 1 }
                    case .fainted:
                        if let down = speciesId(m.pokemon) ?? active[m.side] { fainted[m.side]!.insert(down) }
                        actions[m.side]!.append("faint")
                        if let into = speciesId(m.other) { active[m.side] = into }
                    }
                }
            }
            // Yours as your buttons showed it, where both agree: the energy nearest the model's
            // count, a whole number of fast moves from it if the reading allows.
            if let f = fill[turn], let p = active[.you], let costs = buttonCosts[p] {
                var e = energy[.you]![p] ?? 0
                // Past a button's cost once it has shown full, until a charged move takes you below.
                let was = past[p] ?? (false, false)
                let near = energies(left: f[1], f[2], costs: costs, past: was).map { $0.lowerBound > Double(e) ? $0.lowerBound : min(Double(e), $0.upperBound) }
                past[p] = (was.left || f[1] >= 0.97, was.right || f[2] >= 0.97)
                if let reading = near.min(by: { abs($0 - Double(e)) < abs($1 - Double(e)) }) {
                    let g = gains[p] ?? 0
                    let snapped = g > 0 ? e + Int(((reading - Double(e)) / Double(g)).rounded()) * g : e
                    e = abs(Double(snapped) - reading) <= 2.5 ? snapped : Int(reading.rounded())
                }
                energy[.you]![p] = min(100, max(0, e))
            }
            // Theirs as ManGo counted it.
            if let c = counted[turn] {
                for (p, e) in c.energy { energy[.them]![p] = e }
                fainted[.them]!.formUnion(c.fainted)
                if let a = c.active { active[.them] = a }
            }

            var row: [String: String] = [
                "battle_id": id, "result": s.result ?? "", "turn": "\(turn)",
                "play_seconds": clock(Double(turn) * turnDuration),
                "video_seconds": s.readTime(at: (Double(turn) + 0.5) * turnDuration).map { String(format: "%.2f", $0 - turnDuration / 2) } ?? "",
                "you_shields": "\(shields[.you]!)", "them_shields": "\(shields[.them]!)",
                "you_active": active[.you].map { fainted[.you]!.contains($0) ? "" : $0 } ?? "",
                "them_active": active[.them].map { fainted[.them]!.contains($0) ? "" : $0 } ?? "",
                "you_action": actions[.you]!.joined(separator: ";"), "them_action": actions[.them]!.joined(separator: ";"),
                "charged_first": Set(throwers).count == 2 ? throwers[0].rawValue : "",
            ]
            for (side, team) in [(BattleSummary.Side.you, yourTeam), (.them, theirTeam)] {
                for (i, p) in team.prefix(3).enumerated() {
                    row["\(side.rawValue)_\(i + 1)"] = p
                    // Blank once it has fainted.
                    row["\(side.rawValue)_\(i + 1)_energy"] = fainted[side]!.contains(p) ? "" : "\(energy[side]![p] ?? 0)"
                }
            }
            rows.append(row)
        }
        // Energy only falls at a throw, so ManGo's count as one threw is the most it had since its
        // last: a fast move it counted and took back at the stop isn't left on the turns before.
        for (i, t) in theirThrows.enumerated() {
            guard let slot = theirTeam.prefix(3).firstIndex(of: t.pokemon) else { continue }
            let key = "them_\(slot + 1)_energy"
            let from = theirThrows[..<i].last { $0.pokemon == t.pokemon }?.turn ?? 0
            for k in stride(from: t.turn - 1, through: from, by: -1) {
                if let v = rows[k][key].flatMap(Int.init), v > t.before { rows[k][key] = "\(t.before)" }
            }
        }

        var battle: [String: String] = [
            "battle_id": id, "recording": recording, "battle_number": "\(number)", "video": video ?? "",
            "result": s.result ?? "", "turns": "\(turnCount)", "play_seconds": clock(s.duration),
            "video_start": s.readTime(at: 0).map { String(format: "%.2f", $0) } ?? "",
            "video_end": s.readTime(at: s.duration).map { String(format: "%.2f", $0) } ?? "",
            "you_charged_moves": "\(counts.youCharged)", "them_charged_moves": "\(counts.themCharged)",
            "you_shields_used": "\(2 - shields[.you]!)", "them_shields_used": "\(2 - shields[.them]!)",
            "you_switches": "\(counts.youSwitches)", "them_switches": "\(counts.themSwitches)",
        ]
        for (i, p) in (s.yourPokemon ?? []).prefix(3).enumerated() {
            battle["you_\(i + 1)"] = p.speciesId
            battle["you_\(i + 1)_fast"] = p.fastMove ?? ""
            battle["you_\(i + 1)_charged"] = p.chargedMoves.joined(separator: ";")
        }
        for (i, p) in theirTeam.prefix(3).enumerated() {
            battle["them_\(i + 1)"] = p
            battle["them_\(i + 1)_fast"] = s.fastMoves.last { $0.side == .them && $0.pokemon == p }?.moveId
                ?? data.recommendedMoves(for: p).fast?.moveId ?? ""
            var seen: [String] = []
            for c in s.chargedMoves where c.side == .them && c.speciesId == p {
                if let m = c.moveId, !seen.contains(m) { seen.append(m) }
            }
            battle["them_\(i + 1)_charged"] = seen.joined(separator: ";")
        }
        return Battle(battle: battle, turns: rows, notes: notes)
    }

    /// Rows as CSV, quoting fields that need it.
    public static func csv(_ rows: [[String: String]], columns: [String]) -> String {
        func field(_ v: String) -> String {
            v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
        }
        return ([columns.joined(separator: ",")] + rows.map { r in columns.map { field(r[$0] ?? "") }.joined(separator: ",") })
            .joined(separator: "\n") + "\n"
    }
}
