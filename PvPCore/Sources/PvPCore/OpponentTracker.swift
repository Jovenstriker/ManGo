import Foundation

/// Length of one PvP turn in seconds.
public let turnDuration: TimeInterval = 0.5
public let maxEnergy = 100

/// Tracks the opponent's energy from time alone.
///
/// The model: once the opponent's fast move is identified, assume they throw it
/// back-to-back with no gaps. Energy is then
/// `banked + completedFastMoves * energyGain`, capped at 100, where completed
/// fast moves are counted from the moment the move was first seen. Charged
/// moves subtract their cost and restart the chain. Charged move cinematics
/// pause the battle clock.
///
/// All methods take `now` as a wall-clock timestamp (e.g. `CACurrentMediaTime()`)
/// so the tracker can be driven by taps, by a vision pipeline, or by tests.
public struct OpponentTracker: Sendable {
    public struct Pokemon: Sendable, Hashable {
        public var speciesId: String
        public var fastMove: Move?
        public var revealedChargedMoves: [Move] = []
        /// Energy settled as of `chainStart` (or as of switching out).
        public var bankedEnergy: Int = 0
        /// Battle-clock time when the current uninterrupted fast move chain began.
        public var chainStart: TimeInterval?
        public var isFainted = false
        /// Its finished stretches of fast moves and charged moves, so its energy can be
        /// replayed with a different fast move (see `reconsiderFastMove`).
        public var history: [Stretch] = []
        public var chargedMovesThrown: [Thrown] = []
        /// Energy the history starts from (0, or what `setEnergy` set).
        public var historyBase = 0
        /// Since it last came in: for the cap on how fast its energy can rise.
        public var stint: Stint?
    }

    /// A Pokémon's time in since it last came in. Its energy can't rise faster than its
    /// fast move allows: one move per move's length of play since it was seen coming in,
    /// plus one for each of your charged moves (the move in progress, or one sneaked in on
    /// it), on top of what it came in with and less what it has thrown.
    public struct Stint: Sendable, Hashable {
        /// Battle time it was seen coming in (less `seenSlack`), plus its switch turn.
        public var start: TimeInterval
        public var entryEnergy: Int
        public var spent = 0
        public var yourChargedMoves = 0
        /// Their charged moves: each can follow a fast move the screen showed late (the
        /// "battle restarted before your buttons came back" correction adds it).
        public var theirChargedMoves = 0
    }

    /// The cap starts this much before a switch is seen: the name shows a moment after.
    static let seenSlack: TimeInterval = 0.25

    /// A stretch of back-to-back fast moves, ended by a charged move or a switch.
    public struct Stretch: Sendable, Hashable {
        public var length: TimeInterval
        /// Ended by your charged move, so the fast move in progress counted too.
        public var interrupted: Bool
    }

    /// A charged move thrown after `afterStretch` stretches.
    public struct Thrown: Sendable, Hashable {
        public var afterStretch: Int
        public var cost: Int
    }

    public struct ChargedMoveStatus: Sendable, Hashable, Identifiable {
        public let move: Move
        public let isRevealed: Bool
        public let isRecommended: Bool
        public let ready: Bool
        /// Fast moves still needed before this can be thrown.
        public let fastMovesNeeded: Int
        /// Turns until this can be thrown. `nil` if the fast move is unknown.
        public let turnsUntilReady: Int?
        public var id: String { move.moveId }
    }

    public struct Snapshot: Sendable {
        public let pokemon: Pokemon?
        public let energy: Int
        public let isPaused: Bool
        /// Turns into the fast move currently being performed (0-based).
        public let turnIntoFastMove: Int?
        public let chargedMoves: [ChargedMoveStatus]
    }

    public let data: GameData
    public private(set) var team: [Pokemon] = []
    public private(set) var activeIndex: Int?

    private var pausedAt: TimeInterval?
    private var pausedTotal: TimeInterval = 0
    /// Battle time of the opponent's last charged move; a switch right after it is free.
    private var lastChargedMoveAt: TimeInterval?
    /// What your charged move this stop added for their fast move in progress, and to whom;
    /// and what `opponentThrewOnSameTurn` took back, in case their move shows it shouldn't.
    private var inProgressBonus: (index: Int, energy: Int)?
    private var takenBack: (index: Int, energy: Int)?
    /// The sneak `playerThrewChargedMove` counted straight after their charged move, until
    /// the next stop: taken back if they switch out instead (`switchingOutAfterStop`).
    private var sneak: (index: Int, energy: Int)?

    public init(data: GameData) {
        self.data = data
    }

    public var active: Pokemon? { activeIndex.map { team[$0] } }
    public var isPaused: Bool { pausedAt != nil }

    // MARK: Events


    /// The opponent's lead appeared, they switched, or their next Pokémon came out after a faint.
    /// The outgoing Pokémon keeps its energy. If the incoming fast move is already
    /// known (seen before, or the species has only one), its chain starts once the
    /// switch completes: 1 turn, or 0 for the lead, a switch right after the
    /// opponent's charged move, or `freeSwitch`.
    ///
    /// `assumeFastMove` fills in a fast move that hasn't been seen yet (e.g. PvPoke's
    /// recommended one), so counting starts without a tap. `identifyFastMove` corrects it.
    /// `freeSwitch` makes the switch take 0 turns, e.g. right after a faint.
    public mutating func setActive(
        speciesId: String, at now: TimeInterval, assumeFastMove: String? = nil, freeSwitch: Bool = false,
        seenAt: TimeInterval? = nil
    ) {
        let t = battleTime(at: now)
        let switchTurns = activeIndex == nil || freeSwitch || justThrewChargedMove(atBattleTime: t) ? 0 : 1
        lastChargedMoveAt = nil
        if let i = activeIndex {
            team[i].bankedEnergy = energy(of: team[i], atBattleTime: t)
            closeStretch(i, at: t)
            team[i].chainStart = nil
        }

        if let i = team.firstIndex(where: { $0.speciesId == speciesId }) {
            activeIndex = i
            team[i].isFainted = false  // back in, so it was a switch after all
        } else {
            var p = Pokemon(speciesId: speciesId)
            let fast = data.fastMoves(for: speciesId)
            if fast.count == 1 { p.fastMove = fast[0] }
            team.append(p)
            activeIndex = team.count - 1
        }
        if let i = activeIndex, team[i].fastMove == nil, let id = assumeFastMove,
           let move = data.fastMoves(for: speciesId).first(where: { $0.moveId == id }) {
            team[i].fastMove = move
        }
        if let i = activeIndex, team[i].fastMove != nil {
            team[i].chainStart = t + Double(switchTurns) * turnDuration
        }
        if let i = activeIndex {
            // Timed from when it was seen, so a clock started too early can't add energy.
            let seen = seenAt.map { max(t, battleTime(at: $0) - Self.seenSlack) } ?? t
            team[i].stint = Stint(start: seen + Double(switchTurns) * turnDuration, entryEnergy: team[i].bankedEnergy)
        }
    }

    /// Corrects the active Pokémon's form (e.g. Ninetales -> Alolan Ninetales) without
    /// touching its energy. The fast move is kept if the new form can learn it.
    public mutating func changeForm(to speciesId: String) {
        guard let i = activeIndex, data.species[speciesId] != nil,
              !team.contains(where: { $0.speciesId == speciesId })
        else { return }
        let fast = data.fastMoves(for: speciesId)
        team[i].speciesId = speciesId
        // An assumed move the new form can't learn becomes the form's own likeliest one.
        // The battle went on the whole time, so the count is redone with it.
        if let current = team[i].fastMove, !fast.contains(current),
           let move = data.recommendedMoves(for: speciesId).fast ?? fast.first {
            team[i].fastMove = move
            team[i].bankedEnergy = Self.replay(team[i], with: move, openStretch: nil, throwing: nil).energy
        }
        let learnable = data.chargedMoves(for: speciesId)
        team[i].revealedChargedMoves.removeAll { !learnable.contains($0) }
    }

    /// The active opponent was seen starting `moveId`, within its first turn.
    /// Calling this again re-syncs the chain to `now`.
    public mutating func identifyFastMove(_ moveId: String, at now: TimeInterval) {
        guard let i = activeIndex, let move = data.moves[moveId], move.isFast else { return }
        let t = battleTime(at: now)
        team[i].bankedEnergy = energy(of: team[i], atBattleTime: t)
        closeStretch(i, at: t)
        team[i].fastMove = move
        team[i].chainStart = t
    }

    /// The opponent threw a charged move. Pauses the clock for the cinematic;
    /// call `resume(at:)` when the battle continues.
    ///
    /// Only finished fast moves count. (Rounding to the nearest one gave Marowak a 6th
    /// Mud Slap in a recorded battle where it had thrown 5.)
    public mutating func opponentThrewChargedMove(_ moveId: String, at now: TimeInterval) {
        guard let i = activeIndex, let move = data.moves[moveId] else { return }
        let t = battleTime(at: now)
        let current = energy(of: team[i], atBattleTime: t)
        team[i].bankedEnergy = max(0, current - move.energy)
        team[i].stint?.spent += min(current, move.energy)
        team[i].stint?.theirChargedMoves += 1
        closeStretch(i, at: t)
        team[i].chargedMovesThrown.append(Thrown(afterStretch: team[i].history.count, cost: move.energy))
        if team[i].chainStart != nil { team[i].chainStart = t }
        lastChargedMoveAt = t
        if !team[i].revealedChargedMoves.contains(move) {
            team[i].revealedChargedMoves.append(move)
        }
        pause(at: now)
    }

    /// You threw a charged move. The clock stops until `resume(at:)`.
    ///
    /// The opponent gets every fast move they've finished plus the one they've started:
    /// your charged move interrupts it, but its energy still counts. That includes when
    /// your moves line up (both ending on the same turn): your charged move takes the
    /// next turn, and they start a new fast move on it, so they get that one too. After
    /// your charged move they start fresh.
    ///
    /// So against a 3-turn move, three of your 2-turn moves line up with two 3-turn ones
    /// and hand them a third, and four give them the same 3 (their 3rd is in progress):
    /// throwing after 1, 4, 7 or 10 fast moves gives them nothing extra.
    ///
    /// Safe to call after `pause(at:)`: the clock is frozen at the pause.
    public mutating func playerThrewChargedMove(at now: TimeInterval, afterTheirChargedMove: Bool = false) {
        pause(at: now)
        // Only your latest charged move's fast move in progress can be taken back by a tie:
        // a second one straight after (no time between) adds none, and ties with theirs on
        // its own. (Two Dynamic Punches in a row, then Stunfisk's Earthquake tied with the
        // second: the Mud Shot from the first stays.)
        inProgressBonus = nil
        takenBack = nil
        // Their switch right after is free only if their charged move came last.
        lastChargedMoveAt = nil
        guard let i = activeIndex, let fast = team[i].fastMove, let start = team[i].chainStart else { return }
        let t = battleTime(at: now)
        // Only if they've had a turn since their chain began: not when you throw straight
        // after their own charged move, or as they come in.
        if t <= start + 1e-6, afterTheirChargedMove, !Rules.off("sneakAfterTheirs") {
            // Straight after their charged move, in the same stop: your charged move takes
            // the next turn, and they start a fast move on it (a sneak), so it counts.
            // (Shadow Greninja's Water Shuriken after its Hydro Cannon and your Mandibuzz's
            // throw: without it, its third Hydro Cannon had 32 of 40.)
            let before = team[i].bankedEnergy
            team[i].stint?.yourChargedMoves += 1
            team[i].bankedEnergy = min(maxEnergy, before + fast.energyGain, Self.cap(team[i], atBattleTime: t) ?? maxEnergy)
            inProgressBonus = (i, team[i].bankedEnergy - before)
            sneak = (i, team[i].bankedEnergy - before)
            team[i].history.append(Stretch(length: 0, interrupted: true))
        } else if t > start + 1e-6 {
            let finished = Int((max(0, t - start) / (Double(fast.turns) * turnDuration) + 1e-9).rounded(.down))
            let withFinished = min(maxEnergy, team[i].bankedEnergy + finished * fast.energyGain)
            team[i].stint?.yourChargedMoves += 1
            team[i].bankedEnergy = min(maxEnergy, team[i].bankedEnergy + (finished + (Rules.off("inProgress") ? 0 : 1)) * fast.energyGain,
                                       Self.cap(team[i], atBattleTime: t) ?? maxEnergy)
            inProgressBonus = (i, max(0, team[i].bankedEnergy - withFinished))
            closeStretch(i, at: t, interrupted: true)
        }
        team[i].chainStart = max(t, start)
    }

    /// The opponent threw a charged move on the same turn as yours (charged move priority
    /// decided who went first), so they weren't partway through a fast move: takes back
    /// the one `playerThrewChargedMove` counted in progress. (v11: Altaria's Moonblast came
    /// right after your blocked Sky Attack, on 13 Dragon Breaths, not 14.) Call before
    /// `opponentThrewChargedMove`, in the same stop.
    public mutating func opponentThrewOnSameTurn() {
        guard let (i, bonus) = inProgressBonus, i == activeIndex else { return }
        inProgressBonus = nil
        takenBack = (i, bonus)
        if team[i].stint.map({ $0.yourChargedMoves > 0 }) == true { team[i].stint?.yourChargedMoves -= 1 }
        team[i].bankedEnergy = max(0, team[i].bankedEnergy - bonus)
        if let last = team[i].history.indices.last, team[i].history[last].interrupted {
            team[i].history[last].interrupted = false
        }
    }

    /// They switch out right after the stop: a sneak counted at your charged move didn't
    /// happen, since they chose the switch on that turn, not a fast move. (TestWithMangoV1's
    /// Marowak, after its Rock Slide and your throw, switched to Sableye and came back on 4
    /// Mud Slaps, not 5; Mimikyu after its Shadow Sneak and yours, 54 by hand, not 62.
    /// Shadow Greninja stayed in, and needed its sneak.) Call before `setActive`.
    public mutating func switchingOutAfterStop() {
        guard let (i, energy) = sneak, i == activeIndex else { return }
        sneak = nil
        team[i].bankedEnergy = max(0, team[i].bankedEnergy - energy)
        if team[i].stint.map({ $0.yourChargedMoves > 0 }) == true { team[i].stint?.yourChargedMoves -= 1 }
        if let last = team[i].history.indices.last, team[i].history[last].length == 0 { team[i].history.remove(at: last) }
    }

    /// Their charged move turned out to cost more than they'd have without the fast move
    /// `opponentThrewOnSameTurn` took back: so it wasn't the same turn as yours. They were
    /// partway through a fast move when you threw, it landed, and they threw straight after
    /// yours. Puts it back. (Galarian Stunfisk's Earthquake (65) after your blocked Dynamic
    /// Punch: 62 without its Mud Shot in progress, 71 with it.) Returns whether it did.
    @discardableResult
    public mutating func restoreInProgress(ifShortOf cost: Int, at now: TimeInterval) -> Bool {
        guard let (i, bonus) = takenBack, i == activeIndex else { return false }
        takenBack = nil
        guard energy(of: team[i], atBattleTime: battleTime(at: now)) < cost else { return false }
        team[i].stint?.yourChargedMoves += 1
        team[i].bankedEnergy = min(maxEnergy, team[i].bankedEnergy + bonus)
        if let last = team[i].history.indices.last { team[i].history[last].interrupted = true }
        return true
    }

    /// Your Pokémon fainted in this stop: their next switch is a choice and costs a turn,
    /// even if their charged move came just before.
    public mutating func opponentsNextSwitchCostsATurn() {
        lastChargedMoveAt = nil
    }

    /// Your Pokémon fainted to their fast move: it landed as the battle stopped, so the stop
    /// is on a fast move's end. Counts their fast moves to the nearest end (the stop is only
    /// seen to within a read), and they start fresh when the battle resumes. Call while
    /// paused at the stop.
    public mutating func yourPokemonFainted() {
        guard let p = pausedAt, let i = activeIndex, let fast = team[i].fastMove, let start = team[i].chainStart else { return }
        let t = battleTime(at: p)
        guard t > start + 1e-6 else { return }  // fresh since their charged move
        let duration = Double(fast.turns) * turnDuration
        let landed = max(1, ((t - start) / duration).rounded())
        team[i].bankedEnergy = min(maxEnergy, team[i].bankedEnergy + Int(landed) * fast.energyGain)
        closeStretch(i, at: start + landed * duration)
        team[i].chainStart = t
    }

    /// The opponent's charged move can only start as a fast move's animation finishes. If
    /// the stretch of battle since the last restart (from `stretchStart` to the stop at
    /// `stop`, both wall times, no stops in between) ends partway through a fast move, the
    /// restart guess was off: pick the whole number of fast moves whose implied restart
    /// lies in `restartWindow`. Only adds one when that's the only fit (counting finished
    /// moves already covers the other case). Returns whether it added one.
    @discardableResult
    public mutating func alignToChargedMove(stretchStart: TimeInterval, stop: TimeInterval,
                                            restartWindow: ClosedRange<TimeInterval>) -> Bool {
        guard isPaused, let i = activeIndex, let fast = team[i].fastMove, let start = team[i].chainStart else { return false }
        let frozen = battleTime(at: stop)
        let duration = Double(fast.turns) * turnDuration
        let elapsed = frozen - start
        // Only when their fast moves started at that restart, not partway through the stretch.
        guard elapsed > 0, abs(elapsed - (stop - stretchStart)) < 0.05 else { return false }
        let finished = (elapsed / duration + 1e-9).rounded(.down)
        guard elapsed - finished * duration > 0.05 * duration else { return false }  // already on a boundary
        let restartIfFinished = stop - finished * duration
        let restartIfOneMore = stop - (finished + 1) * duration
        guard !restartWindow.contains(restartIfFinished), restartWindow.contains(restartIfOneMore) else { return false }
        team[i].chainStart = frozen - (finished + 1) * duration
        return true
    }

    /// Marks the active Pokémon fainted without touching the clock, for when the screen
    /// reader has already stopped it and will restart it when the battle resumes. Its
    /// energy is kept in case it was really a switch and it comes back.
    public mutating func markActiveFainted(at now: TimeInterval) {
        guard let i = activeIndex else { return }
        team[i].bankedEnergy = energy(of: team[i], atBattleTime: battleTime(at: now))
        closeStretch(i, at: battleTime(at: now))
        team[i].isFainted = true
        team[i].chainStart = nil
    }

    /// A Pokémon marked fainted turned out to have only switched out (no pokéball went dark):
    /// it's back on the bench with the energy it left with.
    public mutating func markNotFainted(_ speciesId: String) {
        guard let i = team.firstIndex(where: { $0.speciesId == speciesId }) else { return }
        team[i].isFainted = false
    }

    /// Stops the battle clock. No turns pass while either side's charged move plays out.
    public mutating func pause(at now: TimeInterval) {
        if pausedAt == nil { pausedAt = now; sneak = nil }
    }

    public mutating func resume(at now: TimeInterval) {
        guard let p = pausedAt else { return }
        pausedTotal += now - p
        pausedAt = nil
        inProgressBonus = nil
        takenBack = nil
    }

    /// Manually corrects the active opponent's energy (e.g. after a missed event).
    public mutating func setEnergy(_ energy: Int, at now: TimeInterval) {
        guard let i = activeIndex else { return }
        team[i].bankedEnergy = min(maxEnergy, max(0, energy))
        team[i].history = []
        team[i].chargedMovesThrown = []
        team[i].historyBase = team[i].bankedEnergy
        if team[i].chainStart != nil { team[i].chainStart = battleTime(at: now) }
    }

    /// The opponent is about to throw a charged move costing `cost`. If the fast move
    /// ManGo assumed couldn't have given enough energy for it (and every earlier one) but
    /// another fast move the Pokémon learns could, switch to that one, the closest fit if
    /// several do, and recount its energy. Returns the change, if any.
    ///
    /// It can only catch a guess that gives too little energy: one that gives too much
    /// still makes every throw look possible.
    public mutating func reconsiderFastMove(throwing cost: Int, at now: TimeInterval) -> (from: Move, to: Move)? {
        guard let i = activeIndex, let current = team[i].fastMove, let start = team[i].chainStart else { return nil }
        let open = max(0, battleTime(at: now) - start)
        let p = team[i]
        guard !Self.replay(p, with: current, openStretch: open, throwing: cost).possible else { return nil }
        let best = data.fastMoves(for: p.speciesId)
            .filter { $0 != current }
            .map { ($0, Self.replay(p, with: $0, openStretch: open, throwing: cost)) }
            .filter { $0.1.possible }
            .min { $0.1.slack < $1.1.slack }
        guard let (move, _) = best else { return nil }
        team[i].fastMove = move
        team[i].bankedEnergy = Self.replay(p, with: move, openStretch: nil, throwing: nil).energy
        return (current, move)
    }

    /// Replays a Pokémon's energy with `move` as its fast move: each finished stretch
    /// gives its finished fast moves (plus the one in progress if your charged move
    /// interrupted it), capped at 100, and each charged move must have had enough.
    /// `energy` is after the history; `slack` is how much more than needed it had in all.
    static func replay(_ p: Pokemon, with move: Move, openStretch: TimeInterval?, throwing cost: Int?)
        -> (possible: Bool, energy: Int, slack: Int) {
        let duration = Double(move.turns) * turnDuration
        var energy = p.historyBase, possible = true, slack = 0, next = 0
        func spend(after stretches: Int) {
            while next < p.chargedMovesThrown.count, p.chargedMovesThrown[next].afterStretch == stretches {
                let c = p.chargedMovesThrown[next].cost
                if energy < c { possible = false }
                slack += max(0, energy - c)
                energy = max(0, energy - c)
                next += 1
            }
        }
        spend(after: 0)
        for (k, s) in p.history.enumerated() {
            let finished = Int((s.length / duration + 1e-9).rounded(.down))
            energy = min(maxEnergy, energy + (finished + (s.interrupted ? 1 : 0)) * move.energyGain)
            spend(after: k + 1)
        }
        let afterHistory = energy
        if let open = openStretch, let cost {
            let atThrow = min(maxEnergy, energy + Int((open / duration + 1e-9).rounded(.down)) * move.energyGain)
            if atThrow < cost { possible = false }
            slack += max(0, atThrow - cost)
        }
        return (possible, afterHistory, slack)
    }

    /// Ends the active stretch of fast moves at battle time `t`, for the history.
    private mutating func closeStretch(_ i: Int, at t: TimeInterval, interrupted: Bool = false) {
        guard let start = team[i].chainStart, t > start else { return }
        team[i].history.append(Stretch(length: t - start, interrupted: interrupted))
    }

    // MARK: Queries

    public func snapshot(at now: TimeInterval) -> Snapshot {
        let t = battleTime(at: now)
        guard let p = active else {
            return Snapshot(pokemon: nil, energy: 0, isPaused: isPaused, turnIntoFastMove: nil, chargedMoves: [])
        }
        let e = energy(of: p, atBattleTime: t)

        // Seconds into the current fast move; negative while a switch is still completing.
        var progress: TimeInterval?
        var turnInto: Int?
        if let fast = p.fastMove, let start = p.chainStart {
            let moveDuration = Double(fast.turns) * turnDuration
            let elapsed = t - start
            if elapsed < 0 {
                progress = elapsed
            } else {
                progress = elapsed.truncatingRemainder(dividingBy: moveDuration)
                turnInto = Int(progress! / turnDuration)
            }
        }
        let recommended = Set(data.species[p.speciesId]?.recommendedMoveset.dropFirst() ?? [])
        let revealed = Set(p.revealedChargedMoves.map(\.moveId))
        let statuses = data.chargedMoves(for: p.speciesId).map { move -> ChargedMoveStatus in
            let missing = max(0, move.energy - e)
            var needed = 0
            var turns: Int? = missing == 0 ? 0 : nil
            if missing > 0, let fast = p.fastMove {
                needed = Int((Double(missing) / Double(fast.energyGain)).rounded(.up))
                let seconds = Double(needed * fast.turns) * turnDuration - (progress ?? 0)
                turns = Int((seconds / turnDuration).rounded(.up))
            }
            return ChargedMoveStatus(
                move: move,
                isRevealed: revealed.contains(move.moveId),
                isRecommended: recommended.contains(move.moveId),
                ready: missing == 0,
                fastMovesNeeded: needed,
                turnsUntilReady: turns
            )
        }
        .sorted { a, b in
            let ra = a.isRevealed ? 0 : a.isRecommended ? 1 : 2
            let rb = b.isRevealed ? 0 : b.isRecommended ? 1 : 2
            return ra != rb ? ra < rb : a.move.energy < b.move.energy
        }

        return Snapshot(
            pokemon: p, energy: e, isPaused: isPaused,
            turnIntoFastMove: turnInto, chargedMoves: statuses
        )
    }

    // MARK: Internals

    /// Wall time with charged move pauses removed.
    private func battleTime(at now: TimeInterval) -> TimeInterval {
        let pausedNow = pausedAt.map { now - $0 } ?? 0
        return now - pausedTotal - pausedNow
    }

    private func justThrewChargedMove(atBattleTime t: TimeInterval) -> Bool {
        guard let c = lastChargedMoveAt else { return false }
        return t - c < turnDuration
    }

    private func energy(of p: Pokemon, atBattleTime t: TimeInterval) -> Int {
        guard let fast = p.fastMove, let start = p.chainStart else { return p.bankedEnergy }
        let moveDuration = Double(fast.turns) * turnDuration
        let moves = max(0, t - start) / moveDuration
        // Small epsilon so a time landing exactly on a boundary counts that move as finished.
        let completed = Int((moves + 1e-9).rounded(.down))
        return min(maxEnergy, p.bankedEnergy + completed * fast.energyGain, Self.cap(p, atBattleTime: t) ?? maxEnergy)
    }

    /// The most energy `p` can physically have at battle time `t` this stint (see Stint).
    static func cap(_ p: Pokemon, atBattleTime t: TimeInterval) -> Int? {
        guard !Rules.off("cap"), let s = p.stint, let fast = p.fastMove else { return nil }
        let moveDuration = Double(fast.turns) * turnDuration
        let moves = Int((max(0, t - s.start) / moveDuration + 1e-9).rounded(.down)) + s.yourChargedMoves
            + s.theirChargedMoves + 1  // and the one being corrected for at their next throw
        return max(0, s.entryEnergy - s.spent + moves * fast.energyGain)
    }
}
