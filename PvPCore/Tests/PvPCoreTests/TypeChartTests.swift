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
