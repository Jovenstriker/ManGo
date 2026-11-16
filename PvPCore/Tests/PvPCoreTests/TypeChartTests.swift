import Foundation
import Testing
@testable import PvPCore

@Test func superEffectiveOnlyAboveNeutral() {
    // Powder Snow on Fearow: Ice beats Flying. Ember is neutral on it.
    #expect(TypeChart.effect("ice", against: ["normal", "flying"]) == .superEffective)
    #expect(TypeChart.effect("fire", against: ["normal", "flying"]) == .neutral)
    // A weakness and a resistance cancel: Rock on Blaziken (Fire/Fighting), Fighting on
    // Alolan Ninetales (Ice/Fairy). The game shows nothing.
    #expect(TypeChart.effect("rock", against: ["fire", "fighting"]) == .neutral)
    #expect(TypeChart.effect("fighting", against: ["ice", "fairy"]) == .neutral)
    // An immunity is a double resistance: Ghost on Normal, Dragon on Fairy.
    #expect(TypeChart.multiplier("ghost", against: ["normal"]) == 0.390625)
    #expect(TypeChart.effect("dragon", against: ["ghost", "fairy"]) == .notVeryEffective)
}

@Test func gameDataReadsTypes() throws {
    let json = #"{"pokemon":[{"speciesId":"dunsparce","speciesName":"Dunsparce","types":["normal","none"],"fastMoves":[],"chargedMoves":[]}],"moves":[]}"#
    let data = try GameData(gamemasterJSON: Data(json.utf8))
    #expect(data.species["dunsparce"]?.types == ["normal"])
}

@Test func unrankedMegaTakesItsBaseFormsMoveset() throws {
    // PvPoke's Great League rankings have Sableye but not Mega Sableye.
    let sableye = #"["FEINT_ATTACK","SHADOW_CLAW"],"chargedMoves":["FOUL_PLAY","POWER_GEM"]"#
    let gm = #"{"pokemon":[{"speciesId":"sableye","speciesName":"Sableye","types":["dark","ghost"],"fastMoves":"# + sableye
        + #"},{"speciesId":"sableye_mega","speciesName":"Sableye (Mega)","types":["dark","ghost"],"fastMoves":"# + sableye
        + #"}],"moves":[]}"#
    let rankings = #"[{"speciesId":"sableye","moveset":["SHADOW_CLAW","FOUL_PLAY","POWER_GEM"]}]"#
    let data = try GameData(gamemasterJSON: Data(gm.utf8), rankingsJSON: Data(rankings.utf8))
    #expect(data.species["sableye_mega"]?.recommendedMoveset == ["SHADOW_CLAW", "FOUL_PLAY", "POWER_GEM"])
    #expect(data.species["sableye_mega"]?.rank == nil)
}
