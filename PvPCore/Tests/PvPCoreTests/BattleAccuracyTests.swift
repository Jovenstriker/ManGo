import Foundation
import Testing
@testable import PvPCore

/// Accuracy tests deliberately fail on known inaccuracies. Do not replace evidence with
/// the engine's current output or mark these failures as expected just to turn CI green.
private struct BattleEvidence: Decodable {
    let counts: [Int?]
    let countTargets: [Target]?
    let energyCheckpoints: [Checkpoint]?
    let throwEnergy: [ThrowEnergy]?
    let observedFastMoves: [String: String]?

    struct Target: Decodable {
        let speciesId: String
        let moveId: String
    }
    struct Checkpoint: Decodable {
        let time: Double
        let speciesId: String
        let energy: Int
    }
    struct ThrowEnergy: Decodable {
        let ordinal: Int  // 1-based across the recording, including multiple battles
        let speciesId: String
        let moveId: String
        let exact: Int?
        let minimum: Int?
    }
}

private func evidence() throws -> [String: BattleEvidence] {
    let url = try #require(Bundle.module.url(forResource: "hand-counts", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode([String: BattleEvidence].self, from: Data(contentsOf: url))
}

private let recordedFixtures: [String] = (Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Fixtures") ?? [])
    .map { $0.deletingPathExtension().lastPathComponent }.filter { $0 != "hand-counts" }.sorted()

private func replayForAccuracy(_ name: String) throws -> (throwsSeen: [BattleAutomation.ChargedMoveObservation], checkpoints: [Int?]) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let resources = root.appending(path: "App/ManGo/Resources")
    let data = try GameData(gamemasterJSON: Data(contentsOf: resources.appending(path: "gamemaster.json")),
                            rankingsJSON: Data(contentsOf: resources.appending(path: "rankings-1500.json")))
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    let reads = try JSONDecoder().decode([ScreenRead].self, from: Data(contentsOf: url))
    #expect(!reads.isEmpty, "\(name): recording is empty")
    let points = try evidence()[name]?.energyCheckpoints ?? []
    var checkpoints = [Int?](repeating: nil, count: points.count)
    var automation = BattleAutomation(data: data)
    var tracker = OpponentTracker(data: data)
    var throwsSeen: [BattleAutomation.ChargedMoveObservation] = []
    for read in reads {
        automation.process(read, tracker: &tracker)
        throwsSeen += automation.throwsThisRead
        for (i, point) in points.enumerated() where checkpoints[i] == nil && read.time >= point.time {
            // First read at the checkpoint; don't wait for a later, conveniently matching species.
            #expect(read.time - point.time < 0.5, "\(name): no timely read at \(point.time)s")
            // A base name cannot identify a form before a distinguishing move appears.
            #expect(tracker.active?.possibleSpeciesIds.contains(point.speciesId) == true,
                    "\(name): true form excluded at \(point.time)s")
            checkpoints[i] = tracker.snapshot(at: read.time).energy
        }
    }
    return (throwsSeen, checkpoints)
}

@Test func handEvidenceInventoryIsComplete() throws {
    let all = try evidence()
    #expect(recordedFixtures.count >= 24)
    #expect(all.values.filter { $0.counts.contains { $0 != nil } }.count == 9)
    #expect(all.values.flatMap(\.counts).compactMap { $0 }.count == 36)
    for (name, entry) in all {
        #expect(recordedFixtures.contains(name), "Missing recording for \(name)")
        if !entry.counts.isEmpty { #expect(entry.countTargets?.count == entry.counts.count, "\(name): label identities missing") }
    }
}

@Test(arguments: recordedFixtures)
func recordingsRespectGroundTruthAndAffordability(_ name: String) throws {
    let replay = try replayForAccuracy(name)
    #expect(!replay.throwsSeen.isEmpty, "\(name): no charged moves detected")
    // Necessary, not sufficient: an overestimate may still afford every throw. The raw
    // estimate, before the observed spend tops it up: after that every throw is affordable.
    for (i, observed) in replay.throwsSeen.enumerated() {
        #expect(observed.energyBeforeReconciliation >= observed.move.energy,
                "\(name) throw \(i + 1), \(observed.speciesId) \(observed.move.moveId): estimated \(observed.energyBeforeReconciliation), costs \(observed.move.energy)")
    }
    guard let entry = try evidence()[name] else { return }
    for (i, count) in entry.counts.enumerated() {
        guard let count else { continue }  // Unknown is not zero and is not an exact label.
        let observed = try #require(replay.throwsSeen.indices.contains(i) ? replay.throwsSeen[i] : nil,
                                    "\(name): missing labelled throw \(i + 1)")
        let target = try #require(entry.countTargets.flatMap { $0.indices.contains(i) ? $0[i] : nil })
        #expect(observed.speciesId == target.speciesId, "\(name) throw \(i + 1): wrong Pokémon")
        #expect(observed.move.moveId == target.moveId, "\(name) throw \(i + 1): wrong charged move")
        #expect(observed.fastMoveCount == count, "\(name) throw \(i + 1): hand-counted \(count) fast moves")
    }
    for (i, point) in (entry.energyCheckpoints ?? []).enumerated() {
        #expect(replay.checkpoints[i] == point.energy, "\(name) at \(point.time)s: expected \(point.energy) energy")
    }
    for point in entry.throwEnergy ?? [] {
        let i = point.ordinal - 1
        let observed = try #require(replay.throwsSeen.indices.contains(i) ? replay.throwsSeen[i] : nil,
                                    "\(name): missing energy-labelled throw \(point.ordinal)")
        #expect(observed.speciesId == point.speciesId)
        #expect(observed.move.moveId == point.moveId)
        if let exact = point.exact { #expect(observed.energyBefore == exact, "\(name) throw \(point.ordinal): exact energy") }
        if let minimum = point.minimum { #expect(observed.energyBeforeReconciliation >= minimum, "\(name) throw \(point.ordinal): minimum energy, not an exact count") }
    }
    // A different fast move only shows once a throw the assumed one couldn't afford reveals
    // it, so check the one ManGo ends up with.
    for (species, move) in entry.observedFastMoves ?? [:] {
        let observed = try #require(replay.throwsSeen.last { $0.speciesId == species })
        #expect(observed.fastMove?.moveId == move, "\(name): observed moveset differs from the assumption")
    }
}
