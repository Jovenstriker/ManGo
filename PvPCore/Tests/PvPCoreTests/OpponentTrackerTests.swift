import Foundation
import Testing
@testable import PvPCore

/// A slice of PvPoke's gamemaster.json and rankings-1500.json.
private let gamemaster = """
{"pokemon":[
 {"speciesId":"medicham","speciesName":"Medicham","fastMoves":["COUNTER","PSYCHO_CUT"],"chargedMoves":["DYNAMIC_PUNCH","ICE_PUNCH","PSYCHIC","POWER_UP_PUNCH"],"tags":["x"]},
 {"speciesId":"azumarill","speciesName":"Azumarill","fastMoves":["BUBBLE","ROCK_SMASH"],"chargedMoves":["HYDRO_PUMP","ICE_BEAM","PLAY_ROUGH"]},
 {"speciesId":"lickitung","speciesName":"Lickitung","fastMoves":["LICK"],"chargedMoves":["BODY_SLAM"]}
],"moves":[
 {"moveId":"COUNTER","name":"Counter","type":"fighting","power":8,"energy":0,"energyGain":6,"cooldown":1000,"turns":2},
 {"moveId":"PSYCHO_CUT","name":"Psycho Cut","type":"psychic","energy":0,"energyGain":9,"turns":2},
 {"moveId":"BUBBLE","name":"Bubble","type":"water","energy":0,"energyGain":11,"turns":3},
 {"moveId":"ROCK_SMASH","name":"Rock Smash","type":"fighting","energy":0,"energyGain":7,"turns":3},
 {"moveId":"LICK","name":"Lick","type":"ghost","energy":0,"energyGain":6,"turns":1},
 {"moveId":"DYNAMIC_PUNCH","name":"Dynamic Punch","type":"fighting","energy":45,"energyGain":0,"turns":1},
 {"moveId":"ICE_PUNCH","name":"Ice Punch","type":"ice","energy":40,"energyGain":0,"turns":1},
 {"moveId":"PSYCHIC","name":"Psychic","type":"psychic","energy":55,"energyGain":0,"turns":1},
 {"moveId":"POWER_UP_PUNCH","name":"Power-Up Punch","type":"fighting","energy":35,"energyGain":0,"turns":1},
 {"moveId":"HYDRO_PUMP","name":"Hydro Pump","type":"water","energy":75,"energyGain":0,"turns":1},
 {"moveId":"ICE_BEAM","name":"Ice Beam","type":"ice","energy":55,"energyGain":0,"turns":1},
 {"moveId":"PLAY_ROUGH","name":"Play Rough","type":"fairy","energy":60,"energyGain":0,"turns":1},
 {"moveId":"BODY_SLAM","name":"Body Slam","type":"normal","energy":35,"energyGain":0,"turns":1}
]}
"""

private let rankings = """
[{"speciesId":"medicham","moveset":["COUNTER","ICE_PUNCH","PSYCHIC"]},
 {"speciesId":"azumarill","moveset":["BUBBLE","ICE_BEAM","PLAY_ROUGH"]}]
"""

private func makeTracker() throws -> OpponentTracker {
    let data = try GameData(gamemasterJSON: Data(gamemaster.utf8), rankingsJSON: Data(rankings.utf8))
    return OpponentTracker(data: data)
}

@Test func parsesPvPokeData() throws {
    let data = try GameData(gamemasterJSON: Data(gamemaster.utf8), rankingsJSON: Data(rankings.utf8))
    #expect(data.species["medicham"]?.recommendedMoveset == ["COUNTER", "ICE_PUNCH", "PSYCHIC"])
    #expect(data.chargedMoves(for: "medicham").prefix(2).map(\.moveId) == ["ICE_PUNCH", "PSYCHIC"])
}

@Test func energyAccruesPerCompletedFastMove() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "medicham", at: 0)
    #expect(t.snapshot(at: 5).energy == 0)  // fast move not identified yet

    t.identifyFastMove("COUNTER", at: 10)  // 6 energy per 2 turns (1s)
    #expect(t.snapshot(at: 10.9).energy == 0)
    #expect(t.snapshot(at: 11).energy == 6)
    #expect(t.snapshot(at: 13.5).energy == 18)
    #expect(t.snapshot(at: 13.5).turnIntoFastMove == 1)
    #expect(t.snapshot(at: 100).energy == 100)  // capped
}

@Test func chargedMoveCountdown() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "medicham", at: 0)
    t.identifyFastMove("COUNTER", at: 0)

    // At 2.5s: 2 Counters done (12 energy), half a turn into the third.
    let ice = try #require(t.snapshot(at: 2.5).chargedMoves.first { $0.move.moveId == "ICE_PUNCH" })
    #expect(ice.isRecommended)
    #expect(!ice.ready)
    #expect(ice.fastMovesNeeded == 5)  // 28 more energy / 6
    #expect(ice.turnsUntilReady == 9)  // 5 Counters = 10 turns, 1 already in progress

    let ready = try #require(t.snapshot(at: 7).chargedMoves.first { $0.move.moveId == "ICE_PUNCH" })
    #expect(ready.ready)  // 7 Counters = 42 energy
}

@Test func chargedMoveSubtractsAndPausesClock() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "medicham", at: 0)
    t.identifyFastMove("COUNTER", at: 0)

    // Detected slightly late (7.2s): rounds to 7 Counters = 42, minus 40.
    t.opponentThrewChargedMove("ICE_PUNCH", at: 7.2)
    #expect(t.snapshot(at: 12).energy == 2)
    #expect(t.snapshot(at: 12).isPaused)

    // 8s cinematic; the clock resumes from where it stopped.
    t.resume(at: 15.2)
    #expect(t.snapshot(at: 16.1).energy == 2)
    #expect(t.snapshot(at: 16.2).energy == 8)
    #expect(t.snapshot(at: 16.2).chargedMoves.first?.move.moveId == "ICE_PUNCH")  // revealed sorts first
}

@Test func playerChargedMoveStillPaysOutTheirFastMoveInProgress() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "azumarill", at: 0)
    t.identifyFastMove("BUBBLE", at: 0)  // 11 energy per 3 turns (1.5s)
    // You throw at 2s: 1 Bubble done, the 2nd started.
    t.playerThrewChargedMove(at: 2)
    #expect(t.snapshot(at: 9).energy == 22)  // the started Bubble counts
    t.resume(at: 10)
    #expect(t.snapshot(at: 11.4).energy == 22)
    #expect(t.snapshot(at: 11.5).energy == 33)  // a fresh Bubble after the charged move
}

@Test func twoTwoTurnMovesBeatOneAgainstAThreeTurnMove() throws {
    // Their Bubble takes 3 turns. Throwing after one of your 2-turn moves (1s) or two (2s),
    // they get one or two Bubbles' energy respectively, since a started Bubble pays out.
    var one = try makeTracker()
    one.setActive(speciesId: "azumarill", at: 0)
    one.identifyFastMove("BUBBLE", at: 0)
    one.playerThrewChargedMove(at: 1)
    #expect(one.snapshot(at: 1).energy == 11)

    var two = try makeTracker()
    two.setActive(speciesId: "azumarill", at: 0)
    two.identifyFastMove("BUBBLE", at: 0)
    two.playerThrewChargedMove(at: 2)
    #expect(two.snapshot(at: 2).energy == 22)

}

@Test func alignedMovesHandThemAnotherFastMove() throws {
    // Three of your 2-turn moves end at 3s, the same turn as their two 3-turn Bubbles.
    // Your charged move takes the next turn, on which they start a third Bubble: it counts.
    var t = try makeTracker()
    t.setActive(speciesId: "azumarill", at: 0)
    t.identifyFastMove("BUBBLE", at: 0)
    t.playerThrewChargedMove(at: 3)
    #expect(t.snapshot(at: 3).energy == 33)
    t.resume(at: 10)
    #expect(t.snapshot(at: 11.4).energy == 33)  // they start fresh after your charged move
    #expect(t.snapshot(at: 11.5).energy == 44)

    // Both on 2-turn moves: aligned on every move, so they always get one more.
    var mirror = try makeTracker()
    mirror.setActive(speciesId: "medicham", at: 0)
    mirror.identifyFastMove("COUNTER", at: 0)  // 6 energy per 2 turns
    mirror.playerThrewChargedMove(at: 2)       // after your 2nd move: their 3rd counts
    #expect(mirror.snapshot(at: 2).energy == 18)
}

@Test func switchingKeepsEnergyPerPokemon() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "medicham", at: 0)
    t.identifyFastMove("COUNTER", at: 0)
    t.setActive(speciesId: "azumarill", at: 5)  // Medicham leaves with 30
    #expect(t.snapshot(at: 8).energy == 0)  // Azumarill's move not seen yet
    t.identifyFastMove("BUBBLE", at: 8)
    #expect(t.snapshot(at: 11).energy == 22)

    // Medicham comes back: fast move already known, so it starts after the 1-turn switch.
    t.setActive(speciesId: "medicham", at: 20)
    #expect(t.snapshot(at: 20).energy == 30)
    #expect(t.snapshot(at: 20).turnIntoFastMove == nil)  // still switching in
    #expect(t.snapshot(at: 21.4).energy == 30)
    #expect(t.snapshot(at: 21.5).energy == 36)
    #expect(t.team.count == 2)
}

@Test func switchTakesOneTurn() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "lickitung", at: 0)  // lead starts immediately
    #expect(t.snapshot(at: 1).energy == 12)
    t.setActive(speciesId: "medicham", at: 1)
    t.setActive(speciesId: "lickitung", at: 3)  // Lick known: starts at 3.5
    #expect(t.snapshot(at: 3.4).energy == 12)
    #expect(t.snapshot(at: 4).energy == 18)

}

@Test func countdownIncludesSwitchTurn() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "medicham", at: 0)
    t.setActive(speciesId: "lickitung", at: 0)  // 0 energy, Lick starts at 0.5
    let slam = try #require(t.snapshot(at: 0).chargedMoves.first)
    #expect(slam.fastMovesNeeded == 6)  // Body Slam 35 / Lick 6
    #expect(slam.turnsUntilReady == 7)  // 6 Licks + 1 switch turn
}

@Test func switchRightAfterChargedMoveIsFree() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "medicham", at: 0)
    t.identifyFastMove("COUNTER", at: 0)
    t.setActive(speciesId: "lickitung", at: 1)  // normal switch: Lick from 1.5
    #expect(t.snapshot(at: 2.5).energy == 12)
    t.opponentThrewChargedMove("BODY_SLAM", at: 4.5)  // 6 Licks = 36, leaves 1
    t.resume(at: 10)
    t.setActive(speciesId: "medicham", at: 10)  // switch straight out of the charged move
    #expect(t.snapshot(at: 10.9).energy == 6)  // Medicham left with 6 at 1s
    #expect(t.snapshot(at: 11).energy == 12)  // first Counter lands 1s in: no switch turn
    t.setActive(speciesId: "lickitung", at: 11)
    #expect(t.snapshot(at: 11).energy == 1)
}
@Test func singleFastMoveSpeciesStartsAutomatically() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "lickitung", at: 0)  // Lick: 6 energy per turn
    #expect(t.snapshot(at: 3).energy == 36)
}
@Test func changeFormKeepsEnergyAndValidFastMove() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "medicham", at: 0)
    t.identifyFastMove("COUNTER", at: 0)
    t.changeForm(to: "lickitung")  // stand-in for a different form: Counter isn't in its moveset
    #expect(t.active?.speciesId == "lickitung")
    #expect(t.active?.fastMove?.moveId == "LICK")  // its only fast move
    #expect(t.team.count == 1)
}

@Test func assumedFastMoveStartsCountingWithoutATap() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "lickitung", at: 0)
    t.setActive(speciesId: "medicham", at: 1, assumeFastMove: "COUNTER")  // 1-turn switch: from 1.5
    #expect(t.active?.fastMove?.moveId == "COUNTER")
    #expect(t.snapshot(at: 2.4).energy == 0)
    #expect(t.snapshot(at: 2.5).energy == 6)
    t.identifyFastMove("PSYCHO_CUT", at: 3)  // correction: 6 banked, then +9 per second
    #expect(t.snapshot(at: 4).energy == 15)
    t.setActive(speciesId: "azumarill", at: 5, assumeFastMove: "NOT_ITS_MOVE")  // ignored if invalid
    #expect(t.active?.fastMove == nil)
}

@Test func recommendedMovesOutsideTheListAreIgnored() throws {
    let gm = """
    {"pokemon":[{"speciesId":"machoke","speciesName":"Machoke","fastMoves":["COUNTER"],"chargedMoves":["CROSS_CHOP"]}],
     "moves":[{"moveId":"COUNTER","name":"Counter","type":"fighting","energy":0,"energyGain":6,"turns":2},
              {"moveId":"CROSS_CHOP","name":"Cross Chop","type":"fighting","energy":35,"energyGain":0,"turns":1},
              {"moveId":"RETURN","name":"Return","type":"normal","energy":40,"energyGain":0,"turns":1}]}
    """
    let rankings = #"[{"speciesId":"machoke","moveset":["COUNTER","CROSS_CHOP","RETURN"]}]"#
    let data = try GameData(gamemasterJSON: Data(gm.utf8), rankingsJSON: Data(rankings.utf8))
    #expect(data.chargedMoves(for: "machoke").map(\.moveId) == ["CROSS_CHOP"])
    let rec = data.recommendedMoves(for: "machoke")
    #expect(rec.fast?.moveId == "COUNTER")
    #expect(rec.charged.map(\.moveId) == ["CROSS_CHOP"])
    #expect(rec.charged.map(\.energy) == [35])
}
