import Foundation
import Observation
import PvPCore
import QuartzCore

/// Runs the opponent energy tracker from the screen reader's battle events.
/// Great League only; there are no manual controls.
@MainActor @Observable
final class TrackerModel {
    private(set) var tracker: OpponentTracker?
    private(set) var loadError: String?

    /// Screen reading: turns reads from the broadcast extension into battle events.
    private var automation: BattleAutomation?
    private var lastReadTime: TimeInterval = 0
    private(set) var lastReadAt: Date?
    /// The screen reader's memory from its latest read, and the highest peak seen this
    /// session, in MB. iOS stops a broadcast extension that goes over about 50 MB.
    private(set) var readerMemoryMB: Double?
    private(set) var readerPeakMemoryMB: Double?
    /// The battle ended ("YOU WIN!"/"YOU LOSE"). It resets on its own when the next starts.
    var isBattleOver: Bool { automation?.isBattleOver ?? false }
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
            if let now = read.memoryMB { readerMemoryMB = now }
            if let peak = read.peakMemoryMB { readerPeakMemoryMB = max(readerPeakMemoryMB ?? 0, peak) }
        }
        self.automation = automation
        self.tracker = tracker
        lastReadAt = .now
    }

    /// The opponent's other Pokémon that haven't fainted, with the energy they'll bring back in.
    var bench: [(speciesId: String, name: String, energy: Int)] {
        guard let tracker else { return [] }
        return tracker.team
            .filter { $0.speciesId != tracker.active?.speciesId && !$0.isFainted }
            .map { ($0.speciesId, data?.species[$0.speciesId]?.speciesName ?? $0.speciesId, $0.bankedEnergy) }
    }

    /// Starts counting with PvPoke's recommended fast move; tapping a fast move corrects it.
    func setActive(_ speciesId: String) {
        let recommended = data?.species[speciesId]?.recommendedMoveset.first
        tracker?.setActive(speciesId: speciesId, at: now(), assumeFastMove: recommended)
    }
}
