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
        rankingsJSON: Data(contentsOf: resources.appending(path: "rankings-1500.json"))
    )
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    let reads = try JSONDecoder().decode([ScreenRead].self, from: Data(contentsOf: url))
    return (data, reads)
}


/// Energy before each opponent charged move, from ManGo's log ("… used Drill Run (48 → 8)").
private func energiesAtThrows(_ log: [String]) -> [Int] {
    log.filter { $0.contains(" used ") }.compactMap { line in
        guard let open = line.range(of: "(", options: .backwards),
              let arrow = line.range(of: " → ", range: open.upperBound..<line.endIndex) else { return nil }
        return Int(line[open.upperBound..<arrow.lowerBound])
    }
}

@Test func replayTracksTheWholeBattle() throws {
    let (data, reads) = try loadBattle()
    var automation = BattleAutomation(data: data)
    var tracker = OpponentTracker(data: data)
    var stops = 0
    var energyAtThrows: [Int] = []

    for read in reads {
        let wasPaused = tracker.isPaused
        automation.process(read, tracker: &tracker)
        if tracker.isPaused && !wasPaused { stops += 1 }
    }
    energyAtThrows = energiesAtThrows(automation.log)

    // Every pause in the recording: the lead waiting for the countdown's GO (named from
    // "Go, Stunfisk!" just before), 7 opponent charged moves, 6 of yours (one back-to-back
    // with theirs), 3 faints, and the end screen.
    #expect(stops == 16)

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
    // Shocks, Cramorant 5 Pecks each time, Fearow 6 Pecks. Fearow's last Peck comes after
    // it shielded your Double Iron Bash, when your buttons came back late: Drill Run can
    // only start as a Peck finishes, which puts the restart 0.6s before the buttons.
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

    // The buttons are back at 20s; the battle resumed 0.25s before that, at 19.75s.
    // Sand Attack: 4 energy per turn, no switch turn after a faint.
    play(Screen(opponent: "Corviknight"), from: 20, to: 22)
    #expect(tracker.snapshot(at: 20.125).energy == 0)
    #expect(tracker.snapshot(at: 20.25).energy == 4)
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
        automation.process(read, tracker: &tracker)
    }
    energyAtThrows = energiesAtThrows(automation.log)
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

    // Counted by watching the recording: Melmetal 6, 6, then 0 Thunder Shocks (9 each):
    // 54 → 19, 73 → 38, 38 → 3. Ninetales: 3 Embers before your Dynamic Punch (2 thrown, 1
    // slipped in as the moves lined up) and 3 after, around a 1-turn pause ManGo can't see,
    // so it counts 7 (63); then 2 (63 → 28, + 18).
    let energies = energiesAtThrows(automation.log)
    #expect(Array(energies.prefix(5)) == [54, 73, 38, 63, 46])

    // Altaria swapped out and came back: it keeps its energy rather than being written off.
    #expect(tracker.team.first { $0.speciesId == "altaria" }?.isFainted == false)
}

/// A fourth real battle, a Fantasy Cup (vs Mimikyu, Turtonator, Granbull), with ManGo's card
/// covering the opponent's name box for much of it. Not used to fit the timing.
@Test func replayFourthBattleWithNameBoxCovered() throws {
    let (data, reads) = try loadBattle("gbl-battle-2026-10-20-v3")
    var automation = BattleAutomation(data: data)
    var tracker = OpponentTracker(data: data)
    for read in reads {
        automation.process(read, tracker: &tracker)
    }
    // The lead comes from the start's "Go, Mimikyu!" (yours first, then theirs), though the
    // name box was covered and you have a Mimikyu too. Granbull (#1014 in Great League, so
    // outside the top 500) comes from its "Go, Granbull!", told apart from your own "Go"s
    // by your name box.
    #expect(tracker.team.map(\.speciesId) == ["mimikyu", "turtonator", "granbull_shadow"])

    // Counted by watching the recording: Mimikyu 2 Shadow Claws (8 each) before switching
    // out, timed from "Go, Turtonator!" rather than when its name showed.
    #expect(tracker.team[0].bankedEnergy == 16)

    // Turtonator threw Dragon Claw, then straight away another (same stop, a fresh
    // "Attack incoming!"); Granbull's Crunch is theirs though its switch-in wasn't seen
    // in the name box.
    let used = automation.log.filter { $0.contains(" used ") }.map { $0.components(separatedBy: " (").dropLast().joined(separator: " (") }
    #expect(used == ["Turtonator used Dragon Claw", "Turtonator used Dragon Claw", "Granbull (Shadow) used Crunch"])
    // Turtonator: 5 Incinerates, then both Dragon Claws. Granbull: switched in during the
    // stop after them, so it starts as the battle restarts: 7 Charms before Crunch, then 1
    // that counts when your charged move interrupts it.
    #expect(energiesAtThrows(automation.log) == [100, 50, 56])
    #expect(automation.log.contains { $0.hasPrefix("You threw a charged move: Granbull (Shadow) 11 → 19") })
}

@Test func attackIncomingIsAnnouncedOncePerChargedMove() throws {
    let (data, _) = try loadBattle()
    var parser = BattleScreenParser(data: data)
    var events: [BattleEvent] = []
    var t: TimeInterval = 0
    func play(_ screen: Screen, for seconds: TimeInterval) {
        for _ in 0..<Int(seconds / 0.25) {
            events += parser.process(screen.read(at: t))
            t += 0.25
        }
    }
    play(Screen(opponent: "Altaria"), for: 2)
    play(Screen(opponent: "Altaria", buttons: false, banner: "Attack incoming!"), for: 2)
    play(Screen(opponent: "Altaria", buttons: false, banner: "Altaria used Flamethrower!"), for: 1)
    #expect(events.filter { $0 == .attackIncoming }.count == 1)
    let incoming = try #require(events.firstIndex(of: .attackIncoming))
    #expect(incoming < events.firstIndex(of: .opponentChargedMove(moveName: "Flamethrower"))!)
}

/// Two more battles with ManGo on screen, hand-counted. Not used to fit the timing.
@Test func replaySeventhAndEighthBattles() throws {
    func replay(_ name: String) throws -> (BattleAutomation, OpponentTracker) {
        let (data, reads) = try loadBattle(name)
        var automation = BattleAutomation(data: data)
        var tracker = OpponentTracker(data: data)
        for read in reads { automation.process(read, tracker: &tracker) }
        return (automation, tracker)
    }
    // v7: Azumarill leads, throws 1 Bubble and switches out; it brings those 11 back.
    // Empoleon used Waterfall rather than PvPoke's Metal Sound, so its 56 is an overcount.
    let (a7, t7) = try replay("gbl-battle-2026-10-20-v7")
    #expect(t7.team.map(\.speciesId) == ["azumarill", "empoleon", "magnezone"])
    #expect(energiesAtThrows(a7.log) == [56, 64, 100, 56])

    // v8: the same 1-Bubble Azumarill lead; Lucario throws Power-Up Punch and Shadow Ball.
    let (a8, t8) = try replay("gbl-battle-2026-10-20-v8")
    #expect(t8.team.map(\.speciesId) == ["azumarill", "lucario", "mawile"])
    #expect(energiesAtThrows(a8.log) == [80, 55, 66, 61, 45])
}

/// v9 (vs Turtonator, Forretress (Shadow), Mimikyu), with the corrections from watching it.
@Test func replayNinthBattle() throws {
    let (data, reads) = try loadBattle("gbl-battle-2026-10-20-v9")
    var automation = BattleAutomation(data: data)
    var tracker = OpponentTracker(data: data)
    var shown: [TimeInterval: (String?, Int)] = [:]
    var benchAt96: Int?
    for read in reads {
        automation.process(read, tracker: &tracker)
        shown[read.time] = (tracker.active?.speciesId, tracker.snapshot(at: read.time).energy)
        if read.time == 97 { benchAt96 = tracker.team.first { $0.speciesId == "forretress_shadow" }?.bankedEnergy }
    }
    // Turtonator's Incinerate knocked out Melmetal: its 20 shows at the faint (the switch
    // prompt at 57.5s), not only once Altaria is in.
    #expect(shown[58]! == ("turtonator", 100))
    // Forretress threw 1 Volt Switch, then switched to Mimikyu just as it finished.
    #expect(benchAt96 == 16)
    // Back in at 2:33: 16 + 2 more Volt Switches by 2:41.
    #expect(shown[161]! == ("forretress_shadow", 48))
    // Their "Go, Mimikyu!" at 3:01.75, though you have a Mimikyu too: your box showed Altaria.
    #expect(tracker.active?.speciesId == "mimikyu")
}

/// v11 (vs Altaria, Mimikyu, Empoleon): their Moonblast came on the same turn as your
/// Sky Attack, so Altaria had no fast move in progress to count.
@Test func replayEleventhBattle() throws {
    let (data, reads) = try loadBattle("gbl-battle-2026-10-23-v11")
    var automation = BattleAutomation(data: data)
    var tracker = OpponentTracker(data: data)
    var shown: [TimeInterval: (String?, Int)] = [:]
    for read in reads {
        automation.process(read, tracker: &tracker)
        shown[read.time] = (tracker.active?.speciesId, tracker.snapshot(at: read.time).energy)
    }
    // 13 Dragon Breaths by your Sky Attack at 0:33, shown from "Attack incoming!" on.
    #expect(shown[46]! == ("altaria", 52))
}
