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

    private var lastTime: TimeInterval = -.infinity
    /// The charged move buttons are hidden.
    private var stopped = false
    /// When they disappeared, if the clock hasn't been stopped yet: it stops at the
    /// charged move's cue, or here after `cueWait` with no cue (a faint).
    private var buttonsHiddenAt: TimeInterval?
    private var resumedAt: TimeInterval = -.infinity
    private var freeSwitchUntil: TimeInterval = -.infinity
    private var opponentThrewThisStop = false
    private var goAt: TimeInterval?

    /// The lead's name box appears about 2s before the countdown's "GO" (measured in a
    /// recorded battle). Used if the "GO" itself is missed.
    static let leadToGo: TimeInterval = 2.0

    /// A switch this soon after the battle resumes counts as part of that stop.
    static let afterStopWindow: TimeInterval = 1.5
    /// When you tap a charged move your buttons vanish at once, but the move waits for your
    /// fast move to finish, and the battle runs until "Get Ready!" (0.25-1.25s later in the
    /// recorded battle). With no cue by this time, it's a faint.
    static let cueWait: TimeInterval = 1.5

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
        lastTime = read.time
        let t = read.time
        if let hidden = buttonsHiddenAt, t - hidden >= Self.cueWait {
            stopClock(at: hidden, &tracker)  // no charged move cue: a faint, stopped when the buttons went
        }
        for event in parser.process(read) {
            switch event {
            case .searching:
                newBattle(&tracker)

            case .battleEnded:
                guard !isBattleOver else { continue }
                isBattleOver = true
                tracker.pause(at: t)
                note("Battle over")

            case .battleStarted:
                // Turn 0. The lead was probably read during the countdown: restart its clock now.
                goAt = t
                if tracker.team.count == 1, tracker.active?.fastMove != nil {
                    tracker.setEnergy(0, at: t)
                }

            case .stopped:
                stopped = true
                opponentThrewThisStop = false
                buttonsHiddenAt = t

            case .opponentChargeStarted:
                // Your buttons vanish the moment their charged move starts (their wait for
                // a fast move to finish is invisible to you), so the battle stopped then.
                if let hidden = buttonsHiddenAt { stopClock(at: hidden, &tracker) }

            case .resumed(let free):
                if let hidden = buttonsHiddenAt { stopClock(at: hidden, &tracker) }  // a short stop with no cue
                stopped = false
                resumedAt = t
                if free { freeSwitchUntil = t + Self.afterStopWindow }
                tracker.resume(at: t)

            case .opponentChargedMove(let moveName):
                guard let (speciesId, move) = resolve(chargedMove: moveName, tracker: tracker) else {
                    note("Couldn't match move “\(moveName)”")
                    continue
                }
                if speciesId != tracker.active?.speciesId {
                    tracker.changeForm(to: speciesId)
                    note("Form: \(data.species[speciesId]?.speciesName ?? speciesId)")
                }
                if let hidden = buttonsHiddenAt { stopClock(at: hidden, &tracker) }  // its cue was missed
                let before = tracker.snapshot(at: t).energy
                tracker.opponentThrewChargedMove(move.moveId, at: t)
                opponentThrewThisStop = true
                note("\(name(tracker.active?.speciesId)) used \(move.name) (\(before) → \(tracker.snapshot(at: t).energy))")

            case .playerChargedMove:
                // The battle stops now. Their fast move in progress pays out; they start
                // fresh after your move.
                stopClock(at: t, &tracker)
                tracker.playerThrewChargedMove(at: t)

            case .opponentAppeared(let match, let since):
                appear(match, at: since, now: t, tracker: &tracker)
            }
        }
    }

    // MARK: Helpers

    private mutating func stopClock(at time: TimeInterval, _ tracker: inout OpponentTracker) {
        guard buttonsHiddenAt != nil else { return }
        buttonsHiddenAt = nil
        tracker.pause(at: time)
    }

    private mutating func newBattle(_ tracker: inout OpponentTracker) {
        isBattleOver = false
        goAt = nil
        stopped = false
        buttonsHiddenAt = nil
        resumedAt = -.infinity
        freeSwitchUntil = -.infinity
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
        if tracker.active == nil {
            // The lead: counting starts at "GO", or about 2s after its name appears.
            time = goAt ?? since + Self.leadToGo
        }

        let speciesId = seen?.speciesId ?? best.speciesId
        let assumed = data.species[speciesId]?.recommendedMoveset.first
        let duringStop = stopped || t - resumedAt < Self.afterStopWindow
        if tracker.active != nil, duringStop, !opponentThrewThisStop {
            // A new Pokémon right after a stop with no charged move from them: theirs fainted.
            // The clock stays as the screen says: if the battle is still stopped, the new
            // Pokémon's first fast move starts when it resumes, so it comes in at 0.
            note("\(name(tracker.active?.speciesId)) fainted")
            tracker.markActiveFainted()
        }
        // A name change during a stop is a faint replacement or a switch right after their
        // charged move: both take 0 turns.
        let free = stopped || time < freeSwitchUntil
        tracker.setActive(speciesId: speciesId, at: time, assumeFastMove: assumed, freeSwitch: free)
        note("Opponent: \(name(speciesId))")
    }

    /// Finds the charged move by name for the active Pokémon, or for another form with the
    /// same on-screen name (e.g. Discharge means Stunfisk, not Galarian Stunfisk).
    private func resolve(chargedMove name: String, tracker: OpponentTracker) -> (String, Move)? {
        guard let active = tracker.active?.speciesId, let s = data.species[active] else { return nil }
        let key = NameMatcher.normalize(name)
        let base = s.speciesName.split(separator: "(").first.map(String.init) ?? s.speciesName
        let forms = [active] + (parser.matcher.match(base)?.candidates.map(\.speciesId).filter { $0 != active } ?? [])
        for id in forms {
            let moves = data.chargedMoves(for: id)
            if let move = moves.first(where: { NameMatcher.normalize($0.name) == key })
                ?? moves.first(where: { NameMatcher.editDistance(NameMatcher.normalize($0.name), key, limit: 2) <= 2 }) {
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
