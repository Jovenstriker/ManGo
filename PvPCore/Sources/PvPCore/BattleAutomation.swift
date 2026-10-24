import Foundation

/// Drives an `OpponentTracker` from screen reads, with no taps:
/// - the clock stops whenever the battle UI is gone (charged moves, faints) and restarts when it's back
/// - the opponent's charged moves subtract their cost; a move only one form can learn fixes the form
/// - a new name in the top-right is a switch, a faint replacement, or (as a 4th name) a new battle
public struct BattleAutomation: Sendable {
    public private(set) var parser: BattleScreenParser
    public let data: GameData
    /// What happened, newest last, for showing in the app.
    public private(set) var log: [String] = []
    /// The "YOU WIN!"/"YOU LOSE" screen was shown. The last battle stays on screen until
    /// the next one starts.
    public private(set) var isBattleOver = false
    /// When "YOU WIN!" / "GOOD EFFORT!" was read.
    public private(set) var battleEndedAt: TimeInterval?
    // Timing, fitted on four recorded battles against the opponent's fast move counts
    // counted by watching the recordings (see "Battle Logs/*.log"): these values get all 26
    // counts and checkpoints exactly, as do several neighbors.
    // Reads come 4 times a second, so the screen changed up to 0.25s before it's seen.

    /// The battle stops this long before your buttons are first read as gone.
    public var stopLead: TimeInterval = 0.125
    /// For your charged moves, the battle runs on while your fast move finishes and
    /// freezes this long before "Get Ready!" is read (if that's after the buttons vanish).
    public var playerFreezeBeforeCue: TimeInterval = 0.75
    /// The battle resumes this long before your buttons are read again after a charged move...
    public var resumeLead: TimeInterval = 0.25
    /// ...and this long after a faint, when the next Pokémon comes in. (Fearow after
    /// Cramorant's faint, and Ninetales after Melmetal's, both start counting about when
    /// your buttons come back.)
    public var faintResumeLead: TimeInterval = 0.25
    /// Where the battle restarts relative to your buttons coming back, used with "a charged
    /// move starts as a fast move finishes" to correct the restart guess when the opponent
    /// throws. When the opponent shields your charged move ("BLOCKED!") the buttons come
    /// back late (Fearow restarted 0.6s before them); otherwise, including when you shield
    /// theirs, the restart is around them (Melmetal's straight-away Double Iron Bash
    /// restarted about when they came back, Ninetales about 0.4s after).
    /// The battle's first turn begins this long after "GO" is first read: GO stays on screen
    /// a moment before anyone can attack. (The phone-saved Doublade battle: 7 Shadow Claws,
    /// not 8.) 0.15-0.25s all fit every hand count; with no countdown or GO at all, the
    /// lead's clock starts with your buttons instead.
    public var goDelay: TimeInterval = 0.2
    public var restartWindowAfterShield: ClosedRange<TimeInterval> = -0.8 ... -0.2
    public var restartWindow: ClosedRange<TimeInterval> = -0.5 ... 0.4
    /// Testing: start these species on a given fast move instead of PvPoke's recommended one.
    public var assumedFastMoves: [String: String] = [:]
    private var buttonsBackAt: TimeInterval?
    private var shieldedThisStop = false
    private var playerChargedThisStop = false
    /// Their charged move came after yours in this stop, so yours being blocked wasn't the last thing.
    private var opponentThrewAfterYours = false
    private var lastResumeAfterShield = false
    private var chargedMoveThisStop = false

    private var lastTime: TimeInterval = -.infinity
    private var previousReadTime: TimeInterval = -.infinity
    /// The charged move buttons are hidden, and the clock is stopped.
    private var stopped = false
    private var lastStopAt: TimeInterval = -.infinity
    private var resumedAt: TimeInterval = -.infinity
    private var freeSwitchUntil: TimeInterval = -.infinity
    private var opponentThrewThisStop = false
    /// Your Pokémon fainted in this stop ("Switch in a new Pokémon?").
    private var yourFaintThisStop = false
    /// Red pokéballs in their name box (Pokémon left): the latest count, when it was read,
    /// and when it last went down. A ball goes dark as the Pokémon faints, before the stop is
    /// seen and its replacement named.
    private var opponentAlive: Int?
    private var opponentAliveAt: TimeInterval = -.infinity
    private var aliveDroppedAt: TimeInterval = -.infinity
    /// A drop this long before the stop still belongs to it.
    static let faintBallLead: TimeInterval = 3
    /// Marked fainted before the pokéballs could be read: checked against the next count.
    private var unconfirmedFaint: (speciesId: String, stop: TimeInterval)?
    private var goAt: TimeInterval?
    /// The lead is known but the countdown hasn't reached GO: its clock waits.
    private var awaitingGo = false
    /// When the lead was named while waiting for GO, and when the battle seemed to resume
    /// meanwhile: the buttons show during the countdown.
    private var leadNamedAt: TimeInterval = 0
    private var resumedBeforeGo: TimeInterval?
    /// Longest the lead waits for a GO that isn't read, from when it's named.
    static let goWait: TimeInterval = 4


    /// A switch shown this soon after your buttons come back was chosen during the stop.
    static let quickSwitchWindow: TimeInterval = 0.5

    /// A switch this soon after the battle resumes counts as part of that stop.
    static let afterStopWindow: TimeInterval = 1.5

    public init(data: GameData) {
        self.data = data
        parser = BattleScreenParser(data: data)
    }

    /// Forgets everything, as if the screen reader had just started.
    public mutating func reset() {
        self = BattleAutomation(data: data)
    }

    public mutating func process(_ read: ScreenRead, tracker: inout OpponentTracker) {
        guard read.time > lastTime else { return }
        previousReadTime = lastTime
        lastTime = read.time
        let t = read.time
        if let n = read.opponentAlive {
            if let before = opponentAlive, n < before { aliveDroppedAt = t }
            opponentAlive = n
            opponentAliveAt = t
            if let f = unconfirmedFaint, !stopped {
                unconfirmedFaint = nil
                if aliveDroppedAt < f.stop - Self.faintBallLead {
                    tracker.markNotFainted(f.speciesId)
                    note("\(name(f.speciesId)) switched out, not fainted: \(n) pokéballs still red")
                }
            }
        }
        if awaitingGo, let go = goAt, t >= go {
            // GO itself wasn't read, but the countdown said when it would be.
            awaitingGo = false
            tracker.resume(at: go)
            tracker.setEnergy(0, at: go)
        }
        if awaitingGo, goAt == nil, t >= leadNamedAt + Self.goWait {
            // No countdown at all: go by the buttons.
            awaitingGo = false
            tracker.resume(at: resumedBeforeGo ?? t)
        }
        for event in parser.process(read) {
            switch event {
            case .searching:
                newBattle(&tracker)

            case .battleEnded:
                // The results screen keeps showing it, also after the count is cleared.
                guard !isBattleOver, tracker.active != nil else { continue }
                isBattleOver = true
                battleEndedAt = t
                tracker.pause(at: t)
                note("Battle over")

            case .countdown(let goIn):
                if goAt == nil { goAt = t + goIn + goDelay }

            case .battleStarted:
                // Turn 0, `goDelay` after GO shows. The lead was probably read during the countdown:
                // its clock restarts then (on the first read after, if that's later than now).
                let start = t + goDelay
                goAt = start
                if awaitingGo, start <= t {
                    awaitingGo = false
                    tracker.resume(at: t)
                }
                if !awaitingGo, tracker.team.count == 1, tracker.active?.fastMove != nil {
                    tracker.setEnergy(0, at: start)
                }

            case .stopped:
                // Either side's charged move or a faint: no turns pass from here.
                stopped = true
                opponentThrewThisStop = false
                yourFaintThisStop = false
                chargedMoveThisStop = false
                let stop = max(t - stopLead, previousReadTime, resumedAt)
                lastStopAt = stop
                tracker.pause(at: stop)

            case .shielded:
                shieldedThisStop = true

            case .resumed(let free):
                stopped = false
                let lead = chargedMoveThisStop ? resumeLead : faintResumeLead
                let resume = max(t - lead, lastStopAt)
                resumedAt = resume
                buttonsBackAt = t
                // They blocked yours, and didn't throw their own after (v11's Empoleon did: its
                // next stretch restarted with the buttons, as after any charged move of theirs).
                lastResumeAfterShield = shieldedThisStop && playerChargedThisStop && !opponentThrewAfterYours
                opponentThrewAfterYours = false
                shieldedThisStop = false
                playerChargedThisStop = false
                if free { freeSwitchUntil = resume + Self.afterStopWindow }
                // The buttons show during the countdown: the lead's clock waits for GO.
                if awaitingGo { resumedBeforeGo = resume } else { tracker.resume(at: resume) }

            case .opponentChargedMove(let moveName):
                // Unmatched is usually a half-read banner; the next read has the whole name.
                guard let (speciesId, move) = resolve(chargedMove: moveName, tracker: tracker) else { continue }
                if speciesId != tracker.active?.speciesId {
                    tracker.changeForm(to: speciesId)
                    note("Form: \(data.species[speciesId]?.speciesName ?? speciesId)")
                }
                sameTurnAsYours(&tracker)
                if playerChargedThisStop { opponentThrewAfterYours = true }
                // A throw the assumed fast move couldn't have afforded means it's another one.
                if let change = tracker.reconsiderFastMove(throwing: move.energy, at: lastStopAt) {
                    note("\(name(tracker.active?.speciesId)) uses \(change.to.name), not \(change.from.name): \(move.name) needs \(move.energy) energy")
                }
                alignToOpponentChargedMove(&tracker)
                let before = tracker.snapshot(at: t).energy
                tracker.opponentThrewChargedMove(move.moveId, at: t)
                opponentThrewThisStop = true
                chargedMoveThisStop = true
                note("\(name(tracker.active?.speciesId)) used \(move.name) (\(before) → \(tracker.snapshot(at: t).energy))")

            case .attackIncoming:
                // Corrects the count as the battle freezes, not only once the banner names the move.
                sameTurnAsYours(&tracker)
                alignToOpponentChargedMove(&tracker)

            case .yourPokemonFainted:
                yourFaintThisStop = true
                tracker.opponentsNextSwitchCostsATurn()
                guard !opponentThrewThisStop, !playerChargedThisStop else { continue }
                let before = tracker.snapshot(at: t).energy
                tracker.yourPokemonFainted()
                note("Your Pokémon fainted: \(name(tracker.active?.speciesId)) \(before) → \(tracker.snapshot(at: t).energy) (the fast move that knocked it out landed)")

            case .playerChargedMove:
                // Their fast move in progress pays out; they start fresh after your move.
                let before = playerFreezeBeforeCue
                if t - before > lastStopAt, t - lastStopAt < 2.5, tracker.isPaused {
                    // The battle ran on while your fast move finished: move the freeze later.
                    tracker.resume(at: lastStopAt)
                    lastStopAt = t - before
                    tracker.pause(at: lastStopAt)
                }
                chargedMoveThisStop = true
                playerChargedThisStop = true
                let energyBefore = tracker.snapshot(at: t).energy
                tracker.playerThrewChargedMove(at: t)
                if tracker.active != nil {
                    note("You threw a charged move: \(name(tracker.active?.speciesId)) \(energyBefore) → \(tracker.snapshot(at: t).energy) (its fast move in progress counts)")
                }

            case .opponentAppeared(let match, let since):
                appear(match, at: since, now: t, tracker: &tracker)
            }
        }
    }

    // MARK: Helpers

    /// Their charged move started as a fast move finished: the stretch since the battle
    /// restarted holds a whole number of fast moves.
    private mutating func alignToOpponentChargedMove(_ tracker: inout OpponentTracker) {
        let window = lastResumeAfterShield ? restartWindowAfterShield : restartWindow
        if let back = buttonsBackAt, lastStopAt > resumedAt,
           tracker.alignToChargedMove(stretchStart: resumedAt, stop: lastStopAt,
                                      restartWindow: (back + window.lowerBound)...(back + window.upperBound)) {
            note("\(name(tracker.active?.speciesId)) had finished one more fast move: the battle restarted before your buttons came back")
        }
    }

    /// Their charged move came in the same stop as yours, with no restart between: you
    /// both threw on the same turn, so they had no fast move in progress to count.
    private mutating func sameTurnAsYours(_ tracker: inout OpponentTracker) {
        guard playerChargedThisStop, !opponentThrewThisStop else { return }
        let before = tracker.snapshot(at: lastTime).energy
        tracker.opponentThrewOnSameTurn()
        let after = tracker.snapshot(at: lastTime).energy
        if after != before {
            note("\(name(tracker.active?.speciesId)) threw on the same turn as you: no fast move in progress (\(before) → \(after))")
        }
    }

    private mutating func newBattle(_ tracker: inout OpponentTracker) {
        isBattleOver = false
        battleEndedAt = nil
        goAt = nil
        awaitingGo = false
        stopped = false
        lastStopAt = -.infinity
        buttonsBackAt = nil
        resumedAt = -.infinity
        freeSwitchUntil = -.infinity
        opponentAlive = nil
        opponentAliveAt = -.infinity
        aliveDroppedAt = -.infinity
        unconfirmedFaint = nil
        guard !tracker.team.isEmpty else { return }
        tracker = OpponentTracker(data: data)
        log = []
        note("New battle")
    }

    private mutating func appear(_ match: NameMatcher.Match, at since: TimeInterval, now t: TimeInterval, tracker: inout OpponentTracker) {
        guard let best = match.candidates.first else { return }
        if isBattleOver { newBattle(&tracker) }
        var seen = tracker.team.first { p in match.candidates.contains { $0.speciesId == p.speciesId } }
        if let seen, seen.speciesId == tracker.active?.speciesId { return }
        if seen == nil, tracker.team.count >= 3 {
            newBattle(&tracker)  // a 4th Pokémon: a new battle we missed the start of
            seen = nil
        }
        var time = max(since, resumedAt)  // never before the latest resume
        // Switched in during the stop straight after their charged move (a free switch):
        // it starts as the battle restarts, when your buttons come back (Granbull after
        // Turtonator's Dragon Claws: 7 Charms before Crunch; Cramorant after Stunfisk's
        // Discharge: 5 Pecks before Dive), not when its "Go" or name shows. If your charged
        // move came after theirs, the switch is still timed from the restart but costs a
        // turn (the parser's `freeSwitch`): Turtonator after Mimikyu blocked yours had 3
        // Incinerates plus the one in progress, and Mimikyu left with no extra Shadow Claw.
        if opponentThrewThisStop, let back = buttonsBackAt, back >= resumedAt, t - back < Self.afterStopWindow {
            time = max(resumedAt, min(time, back))
        }
        if tracker.active == nil {
            // The lead: counting starts at "GO" (or when the countdown says it will be).
            // Its name can appear before or after GO, so without either, use the name.
            time = goAt ?? since
        }

        let speciesId = seen?.speciesId ?? best.speciesId
        // PvPoke's recommended fast move, or for a Pokémon it doesn't rank, its first one.
        let assumed = assumedFastMoves[speciesId]
            ?? data.species[speciesId]?.recommendedMoveset.first ?? data.species[speciesId]?.fastMoves.first
        let duringStop = stopped || t - resumedAt < Self.afterStopWindow
        var theirsFainted = tracker.active != nil && duringStop && !opponentThrewThisStop
        // Their pokéballs settle it when they're readable: a ball gone dark around the stop is
        // a faint; none, with the balls read since, a switch (Corviknight for Turtonator 0.26s
        // after your charged move: still 3 red, so it stays on the bench with its energy).
        let ballFaint = aliveDroppedAt > lastStopAt - Self.faintBallLead
        if tracker.active != nil, duringStop, ballFaint || opponentAliveAt > lastStopAt {
            theirsFainted = ballFaint
        }
        // A switch that shows as the battle restarts after a charged move (anyone's, tie or
        // not) was chosen as it ended: it's free and starts at the restart (Sableye after
        // Marowak's Rock Slide and yours, 0.25s after the buttons). One that shows later was
        // made in play and costs a turn (Turtonator, 1.1s after: 3 Incinerates plus the one
        // in progress, not 4 plus one).
        let quick = chargedMoveThisStop && buttonsBackAt.map { since - $0 < Self.quickSwitchWindow } == true
        if quick, let back = buttonsBackAt { time = max(resumedAt, min(time, back)) }
        if theirsFainted {
            // A new Pokémon right after a stop with no charged move from them: theirs fainted.
            // The clock stays as the screen says: if the battle is still stopped, the new
            // Pokémon's first fast move starts when it resumes, so it comes in at 0.
            note("\(name(tracker.active?.speciesId)) fainted or switched out")
            if let id = tracker.active?.speciesId, !ballFaint, opponentAlive != nil {
                unconfirmedFaint = (id, lastStopAt)
            }
            tracker.markActiveFainted(at: time)
        }
        // A name change during a stop is a faint replacement or a switch right after their
        // charged move: both take 0 turns, as does a quick switch (above).
        var free = stopped || time < freeSwitchUntil || quick
        // After your Pokémon fainted, their switch (theirs still in) is a choice and costs a
        // turn, even straight after their charged move: Mimikyu for Turtonator after its
        // Dragon Claw knocked yours out, 2 Shadow Claws by your next throw, not 3.
        if yourFaintThisStop, !theirsFainted { free = false }
        let isLead = tracker.active == nil
        tracker.setActive(speciesId: speciesId, at: time, assumeFastMove: assumed, freeSwitch: free)
        if isLead, goAt == nil {
            // Named before the countdown's GO (from "Go, X!"): nothing happens until then.
            tracker.pause(at: time)
            awaitingGo = true
            leadNamedAt = time
            resumedBeforeGo = nil
        }
        note("Opponent: \(name(speciesId))")
    }

    /// Finds the charged move by name for the active Pokémon, or for another form with the
    /// same on-screen name (e.g. Discharge means Stunfisk, not Galarian Stunfisk).
    private func resolve(chargedMove name: String, tracker: OpponentTracker) -> (String, Move)? {
        guard let active = tracker.active?.speciesId, let s = data.species[active] else { return nil }
        // The banner says "Weather Ball"; PvPoke calls it "Weather Ball (Fire)".
        let key = NameMatcher.normalize(name)
        func moveKey(_ m: Move) -> String {
            NameMatcher.normalize(m.name.split(separator: "(").first.map(String.init) ?? m.name)
        }
        let base = s.speciesName.split(separator: "(").first.map(String.init) ?? s.speciesName
        let forms = [active] + (parser.matcher.match(base)?.candidates.map(\.speciesId).filter { $0 != active } ?? [])
        for id in forms {
            let moves = data.chargedMoves(for: id)
            if let move = moves.first(where: { moveKey($0) == key })
                ?? moves.first(where: { NameMatcher.editDistance(moveKey($0), key, limit: 2) <= 2 }) {
                return (id, move)
            }
        }
        return nil
    }

    private func name(_ speciesId: String?) -> String {
        speciesId.flatMap { data.species[$0]?.speciesName } ?? "?"
    }

    private mutating func note(_ s: String) {
        log.append(s)
        if log.count > 50 { log.removeFirst() }
    }
}
