import Foundation
import Testing
@testable import PvPCore

private func summaries(of name: String) throws -> [BattleSummary] {
    let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "App/ManGo/Resources")
    let data = try GameData(
        gamemasterJSON: Data(contentsOf: resources.appending(path: "gamemaster.json")),
        rankingsJSON: Data(contentsOf: resources.appending(path: "rankings-1500.json")))
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    let reads = try JSONDecoder().decode([ScreenRead].self, from: Data(contentsOf: url))
    var automation = BattleAutomation(data: data)
    var tracker = OpponentTracker(data: data)
    var done: [BattleSummary] = []
    for read in reads {
        automation.process(read, tracker: &tracker)
        done += automation.takeCompletedBattles()
    }
    automation.finishBattle(tracker: tracker)
    return done + automation.takeCompletedBattles()
}

/// 142007, every count confirmed by hand: Florges, Mimikyu and Shadow Sableye against your
/// Jumpluff, Thievul and Blaziken, which you won.
@Test func summaryLaysOutTheBattleAsManGoFollowedIt() throws {
    let all = try summaries(of: "battle-2026-11-08-142007")
    #expect(all.count == 1)
    let s = try #require(all.first)
    #expect(s.result == "won")
    #expect(s.opponentTeam == ["Florges", "Mimikyu", "Sableye (Shadow)"])
    #expect(s.yourTeam == ["Jumpluff", "Thievul", "Blaziken"])

    let theirs = s.chargedMoves.filter { $0.side == .them }
    #expect(theirs.map(\.name) == ["Chilling Water", "Shadow Sneak", "Play Rough", "Moonblast", "Chilling Water", "Chilling Water"])
    #expect(theirs.map(\.energyBefore) == [45, 80, 62, 72, 49, 58])
    let yours = s.chargedMoves.filter { $0.side == .you }
    #expect(yours.map(\.name) == ["Energy Ball", "Energy Ball", "Energy Ball", "Icy Wind", "Energy Ball",
                                  "Blaze Kick", "Blaze Kick", "Blaze Kick"])
    // Mimikyu blocked your first two Energy Balls and Sableye your second Blaze Kick; you
    // blocked Play Rough and the last Chilling Water.
    #expect(s.chargedMoves.filter(\.shielded).map(\.name) == ["Energy Ball", "Energy Ball", "Play Rough", "Chilling Water", "Blaze Kick"])

    // Charged moves in battle order, and nothing on a row overlaps.
    #expect(s.chargedMoves.map(\.time) == s.chargedMoves.map(\.time).sorted())
    for side in [BattleSummary.Side.you, .them] {
        let row = s.fastMoves.filter { $0.side == side }
        #expect(!row.isEmpty)
        for (a, b) in zip(row, row.dropFirst()) { #expect(b.start >= a.end - 1e-6, "\(side) fast moves overlap at \(a.start)") }
    }
    // Their fast moves are ManGo's counts: the 36 before their charged moves (Florges' fourth
    // Fairy Wind before switching to Mimikyu at 3:12.3 included, as the user counted), and
    // Mimikyu's one in progress at your Energy Ball at 3:14, before it fainted.
    let last = try #require(theirs.last?.time)
    #expect(s.fastMoves.filter { $0.side == .them && $0.start < last }.count == 37)
    #expect(s.markers.contains { $0.side == .them && $0.kind == .fainted && $0.pokemon == "Mimikyu" })
    #expect(s.markers.contains { $0.side == .you && $0.kind == .fainted })
    // Seconds of play: charged moves take none.
    #expect((45...55).contains(s.duration))
}

@Test func summaryRoundTripsThroughJSON() throws {
    let s = try #require(try summaries(of: "battle-2026-11-08-144330").first)
    let back = try JSONDecoder().decode(BattleSummary.self, from: JSONEncoder().encode(s))
    #expect(back == s)
}
