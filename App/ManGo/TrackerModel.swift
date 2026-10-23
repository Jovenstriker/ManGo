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
    /// How long the screen reader takes per read, and how often reads arrive, this session.
    private(set) var readTimes = ReadTimes()
    /// Screen reads handled this session. Shown on the card, so a recording shows whether
    /// reads were arriving and the app was keeping up.
    private(set) var readCount = 0
    /// Between battles: the screen reader slows down until the next one starts, and stops
    /// after a few minutes without one.
    private(set) var readerIdle = false
    #if DEBUG
    /// Battles the screen reader saved (video and reads), in Files → On My iPhone → ManGo.
    private(set) var savedRecordings = 0
    #endif

    struct ReadTimes {
        var count = 0
        var totalSeconds = 0.0
        var longestSeconds = 0.0
        var firstReadAt: TimeInterval?
        var lastReadAt: TimeInterval?

        var averageSeconds: Double? { count > 0 ? totalSeconds / Double(count) : nil }
        /// Reads per second actually received (a read is skipped while the last is running).
        var perSecond: Double? {
            guard let first = firstReadAt, let last = lastReadAt, last > first, count > 1 else { return nil }
            return Double(count - 1) / (last - first)
        }

        mutating func add(_ read: ScreenRead) {
            guard let s = read.readSeconds else { return }
            count += 1
            totalSeconds += s
            longestSeconds = max(longestSeconds, s)
            if firstReadAt == nil { firstReadAt = read.time }
            lastReadAt = read.time
        }
    }
    /// The battle ended ("YOU WIN!"/"GOOD EFFORT!"). The final count stays up this long,
    /// then ManGo clears it for the next battle.
    static let clearAfterBattle: TimeInterval = 5
    var isBattleOver: Bool { automation?.isBattleOver ?? false }
    /// The latest thing the screen reader noticed, e.g. "Stunfisk used Discharge (81 → 41)".
    var lastEvent: String? { automation?.log.last }

    var data: GameData? { tracker?.data }
    var isPaused: Bool { tracker?.isPaused ?? false }

    init() {
        load()
        // Reads left over from a previous session belong to an old battle.
        lastReadTime = now()
        BroadcastChannel.idleSince = nil
        #if DEBUG
        savedRecordings = BattleRecordings.collect()
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
                rankingsJSON: Data(contentsOf: rankings)
            )
            tracker = OpponentTracker(data: data)
            automation = BattleAutomation(data: data)
            loadError = nil
        } catch {
            loadError = "Couldn't load PvPoke data: \(error.localizedDescription)"
        }
    }

    // MARK: Screen reading

    /// Starts over: forgets the opponent's team and energy. The screen reader keeps running.
    func reset() {
        guard let data else { return }
        tracker = OpponentTracker(data: data)
        automation?.reset()
        lastReadTime = now()
    }

    /// New reads from the broadcast extension, in order. The automation stops and starts
    /// the clock, subtracts the opponent's charged moves, and follows their switches.
    func handleScreenReads() {
        guard var automation, var tracker else { return }
        let reads = BroadcastChannel.reads(after: lastReadTime)
        guard !reads.isEmpty else { return }
        for read in reads {
            if let ended = automation.battleEndedAt, read.time >= ended + Self.clearAfterBattle, let data {
                tracker = OpponentTracker(data: data)
                automation.reset()
            }
            automation.process(read, tracker: &tracker)
            updateReaderIdle(read, automation: automation, tracker: tracker)
            lastReadTime = read.time
            if let now = read.memoryMB { readerMemoryMB = now }
            if let peak = read.peakMemoryMB { readerPeakMemoryMB = max(readerPeakMemoryMB ?? 0, peak) }
            readTimes.add(read)
            readCount += 1
        }
        self.automation = automation
        self.tracker = tracker
        lastReadAt = .now
    }

    /// Idle from the end of a battle until the next one shows signs of starting: matchmaking,
    /// "Battle starting…", or a new opponent named after the count was cleared.
    private func updateReaderIdle(_ read: ScreenRead, automation: BattleAutomation, tracker: OpponentTracker) {
        if !readerIdle, let ended = automation.battleEndedAt {
            readerIdle = true
            BroadcastChannel.idleSince = ended
            collectRecordings()
        } else if readerIdle {
            let starting = read.lines.contains {
                let key = $0.text.lowercased().filter(\.isLetter)
                return key.contains("findingopponent") || key.contains("battlestarting")
            }
            if starting || (automation.battleEndedAt == nil && tracker.active != nil) {
                readerIdle = false
                BroadcastChannel.idleSince = nil
                collectRecordings()
            }
        }
    }

    /// The reader finishes a battle's recording once it sees it's idle, so the one that just
    /// ended is collected a little later: when the next battle starts, or on the next launch.
    private func collectRecordings() {
        #if DEBUG
        savedRecordings = BattleRecordings.collect()
        #endif
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
