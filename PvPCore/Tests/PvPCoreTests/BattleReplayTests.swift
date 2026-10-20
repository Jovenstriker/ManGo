import Foundation
import Testing
@testable import PvPCore

/// Replays a real Great League battle (Altaria/Mimikyu/Melmetal vs Stunfisk/Cramorant/Fearow),
/// read frame by frame from a screen recording every 0.25s.
private func loadBattle(_ name: String = "gbl-battle-2026-10-20") throws -> (GameData, [ScreenRead]) {
    let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "App/ManGo/Resources")
    let data = try GameData(
        gamemasterJSON: Data(contentsOf: resources.appending(path: "gamemaster.json")),
        rankingsJSON: Data(contentsOf: resources.appending(path: "rankings-1500.json")),
        topRanked: 500
    )
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
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
    let used = automation.log.filter { $0.contains(" used ") }.map { $0.components(separatedBy: " (").dropLast().joined(separator: " (") }
    #expect(used == [
        "Stunfisk used Discharge", "Stunfisk used Discharge", "Stunfisk used Discharge",
        "Cramorant used Dive", "Cramorant used Dive", "Cramorant used Dive",
        "Fearow used Drill Run",
    ])

    // The time-based model holds up: every throw came when the app counted at least the
    // move's cost (40 for all three moves). Fearow's Drill Run and Cramorant's first Dive
    // land exactly on 40. Stunfisk's clock starts at the countdown's "GO" (42.25s), and the
    // battle keeps running between your tap and "Get Ready!" while your fast move finishes.
    // Matches the fast moves counted by watching the recording: Stunfisk 6, 7 and 1 Thunder
    // Shocks, Cramorant 5 Pecks each time, Fearow 6 Pecks.
    #expect(energyAtThrows == [54, 77, 46, 40, 40, 40, 48])
    for energy in energyAtThrows {
        #expect(energy >= 40)
    }

    // "YOU WIN!" ends it: counting stops and the last battle stays on screen.
    #expect(automation.isBattleOver)
    #expect(tracker.isPaused)
    #expect(automation.log.last == "Battle over")
}

@Test func nextBattleStartsFresh() throws {
    let (data, reads) = try loadBattle()
    var automation = BattleAutomation(data: data)
    var tracker = OpponentTracker(data: data)
    // The same battle twice in a row: the second has the same lead, Stunfisk, which
    // must start a new battle rather than continue the old one.
    let second = reads.map { ScreenRead(time: $0.time + 300, lines: $0.lines) }
    for read in reads + second {
        automation.process(read, tracker: &tracker)
    }
    #expect(automation.log.first == "New battle")
    #expect(tracker.team.map(\.speciesId) == ["stunfisk", "cramorant", "fearow"])
    #expect(automation.log.filter { $0.contains(" used ") }.count == 7)
}

@Test func parsesBanners() {
    #expect(BattleScreenParser.parseBanner("Stunfisk used Discharge!")! == ("Stunfisk", "Discharge"))
    #expect(BattleScreenParser.parseBanner("Stunfiskused Discharge!")! == ("Stunfisk", "Discharge"))
    #expect(BattleScreenParser.parseBanner("Altaria úsed Flamethrower!")! == ("Altaria", "Flamethrower"))
    #expect(BattleScreenParser.parseBanner("used Double Iron Bash!*")! == (nil, "Double Iron Bash"))
    #expect(BattleScreenParser.parseBanner("Attack incoming!") == nil)
}

/// Builds screen reads for scripted scenarios, with text in the same places as the real battle.
private struct Screen {
    var opponent: String?
    var buttons = true
    var banner: String?

    func read(at time: TimeInterval) -> ScreenRead {
        var lines: [RecognizedText] = []
        if let opponent { lines.append(.init(text: opponent, box: CGRect(x: 0.82, y: 0.097, width: 0.12, height: 0.0105))) }
        if let banner { lines.append(.init(text: banner, box: CGRect(x: 0.2, y: 0.31, width: 0.6, height: 0.022))) }
        if buttons {
            lines.append(.init(text: "FLAMETHROWER", box: CGRect(x: 0.13, y: 0.94, width: 0.25, height: 0.013)))
            lines.append(.init(text: "SKY ATTACK", box: CGRect(x: 0.6, y: 0.94, width: 0.2, height: 0.013)))
        }
        return ScreenRead(time: time, lines: lines)
    }
}

@Test func pokemonThatComesInDuringAStopStartsAtZeroWhenTheBattleResumes() throws {
    let (data, _) = try loadBattle()
    var automation = BattleAutomation(data: data)
    var tracker = OpponentTracker(data: data)
    func play(_ screen: Screen, from start: TimeInterval, to end: TimeInterval) {
        var t = start
        while t < end - 1e-9 {
            automation.process(screen.read(at: t), tracker: &tracker)
            t += 0.25
        }
    }

    // Azumarill leads and fights until you throw a charged move at 10s.
    play(Screen(opponent: "Azumarill"), from: 0, to: 10)
    // Your charged move: "Get Ready!", then the banner. It knocks Azumarill out, and
    // Corviknight's name appears while the battle is still stopped (14s to 20s).
    play(Screen(opponent: "Azumarill", buttons: false, banner: "Get Ready!"), from: 10, to: 12)
    play(Screen(opponent: "Azumarill", buttons: false, banner: "Altaria used Flamethrower!"), from: 12, to: 14)
    play(Screen(opponent: "Corviknight", buttons: false), from: 14, to: 20)
    #expect(tracker.active?.speciesId == "corviknight")
    #expect(tracker.snapshot(at: 19.4).energy == 0)  // nothing counted during the stop
    #expect(tracker.team.first?.isFainted == true)

    // The buttons are back at 20s; the battle resumed 0.375s before that, at 19.625s.
    // Sand Attack: 4 energy per turn, no switch turn after a faint.
    play(Screen(opponent: "Corviknight"), from: 20, to: 22)
    #expect(tracker.snapshot(at: 20).energy == 0)
    #expect(tracker.snapshot(at: 20.125).energy == 4)
    #expect(tracker.snapshot(at: 22).energy == 16)
}

/// A second real battle (Altaria/Melmetal/Mimikyu vs Marowak/Sableye (Shadow)/Talonflame),
/// recorded with ManGo's overlay card on screen. Partway through, the card was dragged to
/// the bottom of the screen, over the game's charged move buttons.
@Test func replaySecondBattleWithOverlayOnScreen() throws {
    let (data, reads) = try loadBattle("gbl-battle-2026-10-20-mango")
    var automation = BattleAutomation(data: data)
    var tracker = OpponentTracker(data: data)
    var energyAtThrows: [Int] = []
    for read in reads {
        let energyBefore = tracker.snapshot(at: read.time).energy
        let usedBefore = automation.log.filter { $0.contains(" used ") }.count
        automation.process(read, tracker: &tracker)
        if automation.log.filter({ $0.contains(" used ") }).count > usedBefore {
            energyAtThrows.append(energyBefore)
        }
    }
    #expect(tracker.team.map(\.speciesId) == ["marowak", "sableye_shadow", "talonflame"])
    #expect(tracker.team.map(\.isFainted) == [false, false, true])

    // Each charged move once: the overlay's "Drain Punch • 40" isn't mistaken for your
    // move buttons, so the battle doesn't look like it resumed mid-stop.
    let used = automation.log.filter { $0.contains(" used ") }.map { $0.components(separatedBy: " (").dropLast().joined(separator: " (") }
    #expect(used == [
        "Marowak used Rock Slide", "Marowak used Rock Slide",
        "Sableye (Shadow) used Drain Punch", "Sableye (Shadow) used Drain Punch",
        "Sableye (Shadow) used Foul Play", "Sableye (Shadow) used Foul Play",
        "Marowak used Bone Club",
    ])

    // The "GO" read as "CO" still starts Marowak's clock.
    // Every throw is at or above its cost: Rock Slide 45, Drain Punch and Foul Play 40,
    // Bone Club 35.
    // Matches the fast moves counted by watching the recording: Marowak 5 then 4 Mud Slaps,
    // Sableye 5, 5, 7 and 3 Shadow Claws, Marowak (back in with 0) 4 Mud Slaps.
    #expect(energyAtThrows == [50, 45, 40, 40, 56, 40, 40])
    #expect(energyAtThrows.count == 7)
    #expect(zip(energyAtThrows, [45, 45, 40, 40, 40, 40, 35]).allSatisfy { $0 >= $1 })
}

@Test func overlayTextIsIgnored() {
    #expect(BattleScreenParser.isButtonLabel("SHADOW SNEAK"))
    #expect(!BattleScreenParser.isButtonLabel("Drain Punch • 40"))
    #expect(!BattleScreenParser.isButtonLabel("Foul Play"))
    #expect(BattleScreenParser.isOverlayText("vs Sableye (Shadow)"))
    #expect(BattleScreenParser.isOverlayText("Bench: Marowak 0"))
    #expect(BattleScreenParser.isOverlayText("PAUSED"))
    #expect(!BattleScreenParser.isOverlayText("Sableye"))
}

@Test func lossScreenEndsTheBattle() throws {
    let (data, _) = try loadBattle()
    var automation = BattleAutomation(data: data)
    var tracker = OpponentTracker(data: data)
    for i in 0..<8 { automation.process(Screen(opponent: "Azumarill").read(at: Double(i) * 0.25), tracker: &tracker) }
    #expect(tracker.active?.speciesId == "azumarill")
    let loss = ScreenRead(time: 3, lines: [RecognizedText(text: "GOOD EFFORT!", box: CGRect(x: 0.2, y: 0.47, width: 0.6, height: 0.07))])
    automation.process(loss, tracker: &tracker)
    #expect(automation.isBattleOver)
}

/// A third real battle (vs Melmetal, Ninetales (Shadow), Altaria), with the opponent
/// swapping Ninetales and Altaria back and forth. Not used to fit the timing.
@Test func replayThirdBattle() throws {
    let (data, reads) = try loadBattle("gbl-battle-2026-10-20-v2")
    var automation = BattleAutomation(data: data)
    var tracker = OpponentTracker(data: data)
    var throwsSeen: [(move: String, before: Int, after: Int)] = []
    for read in reads {
        let before = tracker.snapshot(at: read.time).energy
        let usedBefore = automation.log.filter { $0.contains(" used ") }.count
        automation.process(read, tracker: &tracker)
        if let last = automation.log.last, automation.log.filter({ $0.contains(" used ") }).count > usedBefore {
            throwsSeen.append((last, before, tracker.snapshot(at: read.time).energy))
        }
    }
    #expect(tracker.team.map(\.speciesId) == ["melmetal", "ninetales_shadow", "altaria"])
    #expect(automation.isBattleOver)

    // "Ninetales used Weather Ball!" matches PvPoke's "Weather Ball (Fire)".
    // Log lines end with the energy, e.g. " (72 → 37)".
    let moves = throwsSeen.map { $0.move.components(separatedBy: " (").dropLast().joined(separator: " (") }
    #expect(moves == [
        "Melmetal used Double Iron Bash", "Melmetal used Double Iron Bash", "Melmetal used Double Iron Bash",
        "Ninetales (Shadow) used Weather Ball (Fire)", "Ninetales (Shadow) used Weather Ball (Fire)",
        "Altaria used Moonblast", "Altaria used Flamethrower",
    ])

    // Counted by watching the recording: Melmetal 6, 6, then 0 Thunder Shocks (9 each).
    #expect(throwsSeen[0].before == 54)
    #expect(throwsSeen[1].before - throwsSeen[0].after == 54)
    #expect(throwsSeen[2].before == throwsSeen[1].after)
    // Ninetales: 3 Embers before your Dynamic Punch (2 thrown, 1 slipped in as the moves
    // lined up) and 3 after, around a 1-turn pause ManGo can't see; then 2. ManGo gets
    // one extra before (the restart after a faint is the least certain timing; no single
    // setting fits this and Fearow in the first battle) and one for the pause.
    #expect(throwsSeen[3].before == 72)
    #expect(throwsSeen[4].before - throwsSeen[3].after == 18)

    // Altaria swapped out and came back: it keeps its energy rather than being written off.
    #expect(tracker.team.first { $0.speciesId == "altaria" }?.isFainted == false)
}
