import CoreGraphics
import Foundation
import Observation
import PvPCore
import QuartzCore

/// Feeds battle events into `OpponentTracker`. Events come from taps for now;
/// the vision pipeline will call the same methods. Great League only.
@MainActor @Observable
final class TrackerModel {
    private(set) var tracker: OpponentTracker?
    private(set) var loadError: String?

    /// Screen reading: turns reads from the broadcast extension into battle events.
    private var automation: BattleAutomation?
    private var lastReadTime: TimeInterval = 0
    private(set) var lastReadAt: Date?
    /// The latest thing the screen reader noticed, e.g. "Stunfisk used Discharge (81 → 41)".
    var lastEvent: String? { automation?.log.last }

    var data: GameData? { tracker?.data }
    var isPaused: Bool { tracker?.isPaused ?? false }

    init() {
        load()
        #if DEBUG
        // Launch with `-demoBattle` to start mid-battle against Medicham, for checking the UI.
        if ProcessInfo.processInfo.arguments.contains("-demoBattle") {
            setActive("azumarill")
            tracker?.setEnergy(42, at: now())
            setActive("medicham")
        }
        #endif
        ScreenTextObserver.start { [weak self] in
            self?.handleScreenReads()
        }
    }

    func now() -> TimeInterval { CACurrentMediaTime() }

    func snapshot(at date: Date) -> OpponentTracker.Snapshot? {
        tracker?.snapshot(at: now())
    }

    func load() {
        do {
            guard let gm = Bundle.main.url(forResource: "gamemaster", withExtension: "json"),
                  let rankings = Bundle.main.url(forResource: "rankings-1500", withExtension: "json")
            else { throw CocoaError(.fileNoSuchFile) }
            let data = try GameData(
                gamemasterJSON: Data(contentsOf: gm),
                rankingsJSON: Data(contentsOf: rankings),
                topRanked: 500
            )
            tracker = OpponentTracker(data: data)
            automation = BattleAutomation(data: data)
            loadError = nil
        } catch {
            loadError = "Couldn't load PvPoke data: \(error.localizedDescription)"
        }
    }

    func newBattle() {
        guard let data else { return }
        tracker = OpponentTracker(data: data)
        automation?.reset()
    }

    // MARK: Screen reading

    /// New reads from the broadcast extension, in order. The automation stops and starts
    /// the clock, subtracts the opponent's charged moves, and follows their switches.
    func handleScreenReads() {
        guard var automation, var tracker else { return }
        let reads = BroadcastChannel.reads(after: lastReadTime)
        guard !reads.isEmpty else { return }
        for read in reads {
            automation.process(read, tracker: &tracker)
            lastReadTime = read.time
        }
        self.automation = automation
        self.tracker = tracker
        lastReadAt = .now
    }

    /// Reads a battle screenshot, for checking the screen reader without a live battle.
    func testScreenshot(_ image: CGImage) async -> String {
        let lines = await Task.detached {
            (try? ScreenTextReader.recognize(in: image, region: ScreenTextReader.fullScreen)) ?? []
        }.value
        guard let data else { return "No PvPoke data." }
        var parser = BattleScreenParser(data: data)
        parser.requiredReads = 1
        for event in parser.process(ScreenRead(time: now(), lines: lines)) {
            if case .opponentAppeared(let match, _) = event {
                apply(match)
                return "Opponent: \(match.candidates.first?.speciesName ?? match.key)"
            }
        }
        return lines.isEmpty ? "No text found in the screenshot." : "Found text, but no opponent name in the top-right box."
    }

    private func apply(_ match: NameMatcher.Match) {
        guard let tracker, let best = match.candidates.first else { return }
        let team = tracker.team
        if let seen = team.first(where: { p in match.candidates.contains { $0.speciesId == p.speciesId } }) {
            if seen.speciesId != tracker.active?.speciesId, !seen.isFainted {
                setActive(seen.speciesId)
            }
            return
        }
        if team.count >= 3 { newBattle() }
        setActive(best.speciesId)
    }

    /// The opponent's other Pokémon that haven't fainted, with the energy they'll bring back in.
    var bench: [(speciesId: String, name: String, energy: Int)] {
        guard let tracker else { return [] }
        return tracker.team
            .filter { $0.speciesId != tracker.active?.speciesId && !$0.isFainted }
            .map { ($0.speciesId, data?.species[$0.speciesId]?.speciesName ?? $0.speciesId, $0.bankedEnergy) }
    }

    /// Other forms sharing the active Pokémon's on-screen name, e.g. Shadow or Alolan.
    var formOptions: [Species] {
        guard let data, let id = tracker?.active?.speciesId, let s = data.species[id] else { return [] }
        let base = s.speciesName.split(separator: "(").first.map(String.init) ?? s.speciesName
        return NameMatcher(data: data).match(base)?.candidates ?? []
    }

    func changeForm(_ speciesId: String) { tracker?.changeForm(to: speciesId) }

    /// Starts counting with PvPoke's recommended fast move; tapping a fast move corrects it.
    func setActive(_ speciesId: String) {
        let recommended = data?.species[speciesId]?.recommendedMoveset.first
        tracker?.setActive(speciesId: speciesId, at: now(), assumeFastMove: recommended)
    }
    func sawFastMove(_ moveId: String) { tracker?.identifyFastMove(moveId, at: now()) }
    func opponentThrewChargedMove(_ moveId: String) { tracker?.opponentThrewChargedMove(moveId, at: now()) }
    func playerThrewChargedMove() { tracker?.playerThrewChargedMove(at: now()) }
    func playerFainted() { tracker?.playerFainted(at: now()) }
    func opponentFainted() { tracker?.opponentFainted(at: now()) }
    func resume() { tracker?.resume(at: now()) }
    func setEnergy(_ energy: Int) { tracker?.setEnergy(energy, at: now()) }
}
