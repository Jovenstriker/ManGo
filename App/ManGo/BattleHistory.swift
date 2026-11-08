import Foundation
import Observation
import PvPCore

/// The battles you've played, newest first, as ManGo followed them. Kept on the phone in
/// Application Support (battles.json), the last `keep`.
@MainActor @Observable
final class BattleHistory {
    private(set) var battles: [BattleSummary] = []
    static let keep = 50
    private let url: URL

    init(url: URL = BattleHistory.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([BattleSummary].self, from: data) {
            battles = saved
        }
    }

    nonisolated static var defaultURL: URL {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "battles.json")
    }

    /// Adds battles that just ended, oldest first.
    func add(_ new: [BattleSummary]) {
        let new = new.filter { b in !battles.contains { $0.id == b.id } }
        guard !new.isEmpty else { return }
        battles = Array((new.reversed() + battles).prefix(Self.keep))
        save()
    }

    func delete(_ id: BattleSummary.ID) {
        battles.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(battles) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
