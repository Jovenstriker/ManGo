import Foundation
import Testing
@testable import PvPCore

/// Replays a real Great League battle (Altaria/Mimikyu/Melmetal vs Stunfisk/Cramorant/Fearow),
/// read frame by frame from a screen recording every 0.25s.
private func loadBattle() throws -> (GameData, [ScreenRead]) {
    let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "App/ManGo/Resources")
    let data = try GameData(
        gamemasterJSON: Data(contentsOf: resources.appending(path: "gamemaster.json")),
        rankingsJSON: Data(contentsOf: resources.appending(path: "rankings-1500.json")),
        topRanked: 500
    )
    let url = try #require(Bundle.module.url(forResource: "gbl-battle-2026-10-20", withExtension: "json", subdirectory: "Fixtures"))
    let reads = try JSONDecoder().decode([ScreenRead].self, from: Data(contentsOf: url))
    return (data, reads)
}

@Test func replayTracksTheWholeBattle() throws {
    let (data, reads) = try loadBattle()
    var automation = BattleAutomation(data: data)
    var tracker = OpponentTracker(data: data)
    var stops = 0
    var energyAtThrows: [Int] = []

    for read in reads {
        let wasPaused = tracker.isPaused
        let energyBefore = tracker.snapshot(at: read.time).energy
        let usedBefore = automation.log.filter { $0.contains(" used ") }.count
        automation.process(read, tracker: &tracker)
        if tracker.isPaused && !wasPaused { stops += 1 }
        if automation.log.filter({ $0.contains(" used ") }).count > usedBefore {
            energyAtThrows.append(energyBefore)
        }
    }

    // Every pause in the recording: 7 opponent charged moves, 6 of yours (one back-to-back
    // with theirs), 3 faints, and the end screen.
    #expect(stops == 15)

    // The opponent's team, in order, with the faint inferred from the screen.
    #expect(tracker.team.map(\.speciesId) == ["stunfisk", "cramorant", "fearow"])
    #expect(tracker.team.map(\.isFainted) == [false, true, false])

    // Their charged moves, each counted once, from the "X used Y!" banners.
    let used = automation.log.filter { $0.contains(" used ") }.map { $0.components(separatedBy: " (").first! }
    #expect(used == [
        "Stunfisk used Discharge", "Stunfisk used Discharge", "Stunfisk used Discharge",
        "Cramorant used Dive", "Cramorant used Dive", "Cramorant used Dive",
        "Fearow used Drill Run",
    ])

    // The time-based model holds up: every throw came when the app counted at least the
    // move's cost (40 for all three moves), give or take one fast move. Cramorant threw
    // all three Dives at exactly 40, once your charged moves pay out its Peck in progress.
    #expect(energyAtThrows == [81, 100, 69, 40, 40, 40, 32])
    for energy in energyAtThrows {
        #expect(energy >= 40 - 9)
    }
}

@Test func parsesBanners() {
    #expect(BattleScreenParser.parseBanner("Stunfisk used Discharge!")! == ("Stunfisk", "Discharge"))
    #expect(BattleScreenParser.parseBanner("Stunfiskused Discharge!")! == ("Stunfisk", "Discharge"))
    #expect(BattleScreenParser.parseBanner("Altaria úsed Flamethrower!")! == ("Altaria", "Flamethrower"))
    #expect(BattleScreenParser.parseBanner("used Double Iron Bash!*")! == (nil, "Double Iron Bash"))
    #expect(BattleScreenParser.parseBanner("Attack incoming!") == nil)
}
