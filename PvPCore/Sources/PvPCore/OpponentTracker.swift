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
        /// The opponent's Pokémon fainted; the clock is stopped until their next one comes out.
        public let awaitingOpponent: Bool
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
    public private(set) var awaitingOpponent = false

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
    /// opponent's charged move, or a replacement after a faint (which also resumes the clock).
    ///
    /// `assumeFastMove` fills in a fast move that hasn't been seen yet (e.g. PvPoke's
    /// recommended one), so counting starts without a tap. `identifyFastMove` corrects it.
    /// `freeSwitch` makes the switch take 0 turns, e.g. right after a faint.
    public mutating func setActive(
        speciesId: String, at now: TimeInterval, assumeFastMove: String? = nil, freeSwitch: Bool = false
    ) {
        let afterFaint = awaitingOpponent
        if afterFaint {
            awaitingOpponent = false
            resume(at: now)
        }
        let t = battleTime(at: now)
        let switchTurns = activeIndex == nil || afterFaint || freeSwitch || justThrewChargedMove(atBattleTime: t) ? 0 : 1
        lastChargedMoveAt = nil
        if let i = activeIndex {
            team[i].bankedEnergy = energy(of: team[i], atBattleTime: t)
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
    }

    /// Corrects the active Pokémon's form (e.g. Ninetales -> Alolan Ninetales) without
    /// touching its energy. The fast move is kept if the new form can learn it.
    public mutating func changeForm(to speciesId: String) {
        guard let i = activeIndex, data.species[speciesId] != nil,
              !team.contains(where: { $0.speciesId == speciesId })
        else { return }
        let fast = data.fastMoves(for: speciesId)
        team[i].speciesId = speciesId
        if let current = team[i].fastMove, !fast.contains(current) {
            team[i].fastMove = nil
            team[i].chainStart = nil
        }
        if team[i].fastMove == nil, fast.count == 1 {
            team[i].fastMove = fast[0]
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
    /// So against a 3-turn move, two of your 2-turn moves then a charged move give them
    /// the same as one (their 2nd move is in progress either way), while three 2-turn
    /// moves line up with two 3-turn ones and hand them a third.
    ///
    /// Safe to call after `pause(at:)`: the clock is frozen at the pause.
    public mutating func playerThrewChargedMove(at now: TimeInterval) {
        pause(at: now)
        guard let i = activeIndex, let fast = team[i].fastMove, let start = team[i].chainStart else { return }
        let t = battleTime(at: now)
        // Only if they've had a turn since their chain began: not when you throw straight
        // after their own charged move, or as they come in.
        if t > start + 1e-6 {
            let finished = Int((max(0, t - start) / (Double(fast.turns) * turnDuration) + 1e-9).rounded(.down))
            team[i].bankedEnergy = min(maxEnergy, team[i].bankedEnergy + (finished + 1) * fast.energyGain)
        }
        team[i].chainStart = max(t, start)
    }

    /// The opponent's active Pokémon fainted. Both sides stop attacking until
    /// their next Pokémon comes out (`setActive`), which then starts with no switch turn.
    public mutating func opponentFainted(at now: TimeInterval) {
        guard let i = activeIndex else { return }
        team[i].isFainted = true
        team[i].chainStart = nil
        awaitingOpponent = true
        pause(at: now)
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
        team[i].isFainted = true
        team[i].chainStart = nil
    }

    /// Your Pokémon fainted. Both sides stop attacking until your next one comes
    /// out (`resume(at:)`). Fainting happens when an attack lands, i.e. at the end of
    /// the opponent's fast move, so their chain is snapped to that boundary.
    public mutating func playerFainted(at now: TimeInterval) {
        if let i = activeIndex, team[i].chainStart != nil {
            let t = battleTime(at: now)
            team[i].bankedEnergy = energy(of: team[i], atBattleTime: t, rounding: .toNearestOrAwayFromZero)
            team[i].chainStart = t
        }
        pause(at: now)
    }

    /// Stops the battle clock. No turns pass while either side's charged move plays out.
    public mutating func pause(at now: TimeInterval) {
        if pausedAt == nil { pausedAt = now }
    }

    public mutating func resume(at now: TimeInterval) {
        guard let p = pausedAt else { return }
        pausedTotal += now - p
        pausedAt = nil
    }

    /// Manually corrects the active opponent's energy (e.g. after a missed event).
    public mutating func setEnergy(_ energy: Int, at now: TimeInterval) {
        guard let i = activeIndex else { return }
        team[i].bankedEnergy = min(maxEnergy, max(0, energy))
        if team[i].chainStart != nil { team[i].chainStart = battleTime(at: now) }
    }

    // MARK: Queries

    public func snapshot(at now: TimeInterval) -> Snapshot {
        let t = battleTime(at: now)
        guard let p = active else {
            return Snapshot(pokemon: nil, energy: 0, isPaused: isPaused, awaitingOpponent: false, turnIntoFastMove: nil, chargedMoves: [])
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
            pokemon: p, energy: e, isPaused: isPaused, awaitingOpponent: awaitingOpponent,
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

    private func energy(
        of p: Pokemon,
        atBattleTime t: TimeInterval,
        rounding: FloatingPointRoundingRule = .down
    ) -> Int {
        guard let fast = p.fastMove, let start = p.chainStart else { return p.bankedEnergy }
        let moveDuration = Double(fast.turns) * turnDuration
        let moves = max(0, t - start) / moveDuration
        // Small epsilon so a time landing exactly on a boundary counts that move as finished.
        let completed = rounding == .down ? Int((moves + 1e-9).rounded(.down)) : Int(moves.rounded(rounding))
        return min(maxEnergy, p.bankedEnergy + completed * fast.energyGain)
    }
}
