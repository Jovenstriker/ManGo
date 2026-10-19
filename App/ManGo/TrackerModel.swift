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

    var data: GameData? { tracker?.data }
    var isPaused: Bool { tracker?.isPaused ?? false }

    init() { load() }

    func now() -> TimeInterval { CACurrentMediaTime() }

    func snapshot(at date: Date) -> OpponentTracker.Snapshot? {
        tracker?.snapshot(at: now())
    }

    func load() {
        do {
            guard let gm = Bundle.main.url(forResource: "gamemaster", withExtension: "json"),
                  let rankings = Bundle.main.url(forResource: "rankings-1500", withExtension: "json")
            else { throw CocoaError(.fileNoSuchFile) }
            let data = try GameData(gamemasterJSON: Data(contentsOf: gm), rankingsJSON: Data(contentsOf: rankings))
            tracker = OpponentTracker(data: data)
            loadError = nil
        } catch {
            loadError = "Couldn't load PvPoke data: \(error.localizedDescription)"
        }
    }

    func newBattle() {
        guard let data else { return }
        tracker = OpponentTracker(data: data)
    }

    func setActive(_ speciesId: String) { tracker?.setActive(speciesId: speciesId, at: now()) }
    func sawFastMove(_ moveId: String) { tracker?.identifyFastMove(moveId, at: now()) }
    func opponentThrewChargedMove(_ moveId: String) { tracker?.opponentThrewChargedMove(moveId, at: now()) }
    func playerThrewChargedMove() { tracker?.playerThrewChargedMove(at: now()) }
    func resume() { tracker?.resume(at: now()) }
    func setEnergy(_ energy: Int) { tracker?.setEnergy(energy, at: now()) }
}
