import Foundation
import PvPCore

// Writes every recorded battle turn by turn, as ManGo counts it, for comparing your play with a
// solver's: battles.csv (one row a battle: teams, movesets, who won) and turns.csv (one row a
// turn: who's in, every Pokémon's energy, shields left, what each side did).
//
//   swift run battle-turns <fixtures dir> <resources dir> <hand-counts.json> <out dir>

let a = CommandLine.arguments
guard a.count == 5 else {
    print("usage: battle-turns <fixtures dir> <resources dir> <hand-counts.json> <out dir>")
    exit(1)
}
let fixtures = URL(fileURLWithPath: a[1])
let res = URL(fileURLWithPath: a[2])
let out = URL(fileURLWithPath: a[4])
let data = try GameData(
    gamemasterJSON: Data(contentsOf: res.appending(path: "gamemaster.json")),
    rankingsJSON: Data(contentsOf: res.appending(path: "rankings-1500.json")))

struct Hand: Decodable { let video: String? }
let hand = (try? JSONDecoder().decode([String: Hand].self, from: Data(contentsOf: URL(fileURLWithPath: a[3])))) ?? [:]

let names = try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
    .filter { ($0.hasPrefix("battle-") || $0.hasPrefix("gbl-battle-")) && $0.hasSuffix(".json") }
    .sorted()
var battles: [[String: String]] = []
var turns: [[String: String]] = []
var noteCount = 0
for file in names {
    let recording = String(file.dropLast(5))
    let reads = try JSONDecoder().decode([ScreenRead].self, from: Data(contentsOf: fixtures.appending(path: file)))
    // As the battle report and tests replay a recording.
    var automation = BattleAutomation(data: data)
    var tracker = OpponentTracker(data: data)
    var summaries: [BattleSummary] = []
    var readings = TurnByTurn.Readings()
    for read in reads {
        automation.process(read, tracker: &tracker)
        readings.add(read, tracker: tracker)
        summaries += automation.takeCompletedBattles()
    }
    automation.finishBattle(tracker: tracker)
    summaries += automation.takeCompletedBattles()
    for (i, s) in summaries.enumerated() {
        let model = TurnByTurn.model(s, id: "\(recording)#\(i + 1)", recording: recording, number: i + 1,
                                     video: hand[recording]?.video, readings: readings, data: data)
        for n in model.notes { FileHandle.standardError.write("\(recording)#\(i + 1): \(n)\n".data(using: .utf8)!) }
        battles.append(model.battle)
        turns += model.turns
        noteCount += model.notes.count
    }
    print("\(recording): \(summaries.count) battle\(summaries.count == 1 ? "" : "s")")
}
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try TurnByTurn.csv(battles, columns: TurnByTurn.battleColumns).write(to: out.appending(path: "battles.csv"), atomically: true, encoding: .utf8)
try TurnByTurn.csv(turns, columns: TurnByTurn.turnColumns).write(to: out.appending(path: "turns.csv"), atomically: true, encoding: .utf8)
print("\(battles.count) battles, \(turns.count) turns, \(noteCount) notes → \(out.path)")
