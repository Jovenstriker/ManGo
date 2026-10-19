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

    /// Screen reading: the name last read from the screen, and when a read last arrived.
    private var detector: OpponentNameDetector?
    private(set) var lastReadName: String?
    private(set) var lastReadAt: Date?

    var data: GameData? { tracker?.data }
    var isPaused: Bool { tracker?.isPaused ?? false }

    init() {
        load()
        ScreenTextObserver.start { [weak self] in
            self?.handleScreenText(BroadcastChannel.latest())
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
            detector = OpponentNameDetector(matcher: NameMatcher(data: data))
            loadError = nil
        } catch {
            loadError = "Couldn't load PvPoke data: \(error.localizedDescription)"
        }
    }

    func newBattle() {
        guard let data else { return }
        tracker = OpponentTracker(data: data)
        detector?.reset()
    }

    // MARK: Screen reading

    /// A read from the broadcast extension. Once a name is read twice in a row it
    /// becomes the active opponent: a name already on their team is a switch, a new
    /// one is added, and a 4th new name means a new battle.
    func handleScreenText(_ lines: [RecognizedText]) {
        lastReadAt = .now
        guard let match = detector?.process(lines) else { return }
        apply(match)
    }

    /// Reads a battle screenshot, for checking the name reader without a live battle.
    func testScreenshot(_ image: CGImage) async -> String {
        let lines = await Task.detached { (try? ScreenTextReader.recognize(in: image)) ?? [] }.value
        let read = lines.map(\.text).joined(separator: ", ")
        guard let match = detector?.bestMatch(in: lines) else {
            return read.isEmpty ? "No text found in the top-right of the screenshot." : "Read “\(read)” but it didn't match a top-500 Pokémon."
        }
        apply(match)
        let name = match.candidates.first?.speciesName ?? match.key
        return "Read “\(read)” → \(name)"
    }

    private func apply(_ match: NameMatcher.Match) {
        guard let tracker, let best = match.candidates.first else { return }
        lastReadName = best.speciesName
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

    /// Other forms sharing the active Pokémon's on-screen name, e.g. Shadow or Alolan.
    var formOptions: [Species] {
        guard let data, let id = tracker?.active?.speciesId, let s = data.species[id] else { return [] }
        let base = s.speciesName.split(separator: "(").first.map(String.init) ?? s.speciesName
        return NameMatcher(data: data).match(base)?.candidates ?? []
    }

    func changeForm(_ speciesId: String) { tracker?.changeForm(to: speciesId) }

    func setActive(_ speciesId: String) { tracker?.setActive(speciesId: speciesId, at: now()) }
    func sawFastMove(_ moveId: String) { tracker?.identifyFastMove(moveId, at: now()) }
    func opponentThrewChargedMove(_ moveId: String) { tracker?.opponentThrewChargedMove(moveId, at: now()) }
    func playerThrewChargedMove() { tracker?.playerThrewChargedMove(at: now()) }
    func playerFainted() { tracker?.playerFainted(at: now()) }
    func opponentFainted() { tracker?.opponentFainted(at: now()) }
    func resume() { tracker?.resume(at: now()) }
    func setEnergy(_ energy: Int) { tracker?.setEnergy(energy, at: now()) }
}
