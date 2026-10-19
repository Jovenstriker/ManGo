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
    #expect(data.search("med").first?.speciesId == "medicham")
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

@Test func playerChargedMoveFreezesOpponentMidFastMove() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "azumarill", at: 0)
    t.identifyFastMove("BUBBLE", at: 0)  // 11 energy per 3 turns (1.5s)
    t.playerThrewChargedMove(at: 2)  // 1 Bubble done, 1 turn into the second
    #expect(t.snapshot(at: 9).energy == 11)
    #expect(t.snapshot(at: 9).turnIntoFastMove == 1)
    t.resume(at: 10)
    #expect(t.snapshot(at: 10.9).energy == 11)
    #expect(t.snapshot(at: 11).energy == 22)  // second Bubble finishes after the remaining 2 turns
}

@Test func switchingKeepsEnergyPerPokemon() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "medicham", at: 0)
    t.identifyFastMove("COUNTER", at: 0)
    t.setActive(speciesId: "azumarill", at: 5)  // Medicham leaves with 30
    #expect(t.snapshot(at: 8).energy == 0)  // Azumarill's move not seen yet
    t.identifyFastMove("BUBBLE", at: 8)
    #expect(t.snapshot(at: 11).energy == 22)

    // Medicham comes back: fast move already known, so the chain starts immediately.
    t.setActive(speciesId: "medicham", at: 20)
    #expect(t.snapshot(at: 20).energy == 30)
    #expect(t.snapshot(at: 22).energy == 42)
    #expect(t.team.count == 2)
}

@Test func singleFastMoveSpeciesStartsAutomatically() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "lickitung", at: 0)  // Lick: 6 energy per turn
    #expect(t.snapshot(at: 3).energy == 36)
}

@Test func manualEnergyCorrection() throws {
    var t = try makeTracker()
    t.setActive(speciesId: "medicham", at: 0)
    t.identifyFastMove("COUNTER", at: 0)
    t.setEnergy(50, at: 4.5)
    #expect(t.snapshot(at: 5.4).energy == 50)
    #expect(t.snapshot(at: 5.5).energy == 56)
}
