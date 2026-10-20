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

    private var lastTime: TimeInterval = -.infinity
    private var stopped = false
    private var resumedAt: TimeInterval = -.infinity
    private var freeSwitchUntil: TimeInterval = -.infinity
    private var opponentThrewThisStop = false

    /// A switch this soon after the battle resumes counts as part of that stop.
    static let afterStopWindow: TimeInterval = 1.5

    public init(data: GameData) {
        self.data = data
        parser = BattleScreenParser(data: data)
    }

    public mutating func reset() {
        parser.reset()
        log = []
    }

    public mutating func process(_ read: ScreenRead, tracker: inout OpponentTracker) {
        guard read.time > lastTime else { return }
        lastTime = read.time
        let t = read.time
        for event in parser.process(read) {
            switch event {
            case .stopped:
                stopped = true
                opponentThrewThisStop = false
                tracker.pause(at: t)

            case .resumed(let free):
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
                let before = tracker.snapshot(at: t).energy
                tracker.opponentThrewChargedMove(move.moveId, at: t)
                opponentThrewThisStop = true
                note("\(name(tracker.active?.speciesId)) used \(move.name) (\(before) → \(tracker.snapshot(at: t).energy))")

            case .playerChargedMove:
                // Their fast move in progress pays out; they start fresh after your move.
                tracker.playerThrewChargedMove(at: t)

            case .opponentAppeared(let match, let since):
                appear(match, at: since, now: t, tracker: &tracker)
            }
        }
    }

    // MARK: Helpers

    private mutating func appear(_ match: NameMatcher.Match, at since: TimeInterval, now t: TimeInterval, tracker: inout OpponentTracker) {
        guard let best = match.candidates.first else { return }
        let time = max(since, resumedAt)  // never before the latest resume
        let team = tracker.team
        let seen = team.first { p in match.candidates.contains { $0.speciesId == p.speciesId } }
        if let seen, seen.speciesId == tracker.active?.speciesId { return }
        if seen == nil, team.count >= 3 {
            tracker = OpponentTracker(data: data)  // a 4th Pokémon: new battle
            log = []
            note("New battle")
        }

        let speciesId = seen?.speciesId ?? best.speciesId
        let assumed = data.species[speciesId]?.recommendedMoveset.first
        let duringStop = stopped || t - resumedAt < Self.afterStopWindow
        if tracker.active != nil, duringStop, !opponentThrewThisStop {
            // A new Pokémon right after a stop with no charged move from them: theirs fainted.
            note("\(name(tracker.active?.speciesId)) fainted")
            tracker.opponentFainted(at: time)
        }
        tracker.setActive(speciesId: speciesId, at: time, assumeFastMove: assumed, freeSwitch: time < freeSwitchUntil)
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
