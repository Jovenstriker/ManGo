#if DEBUG
import Foundation
import PvPCore

/// Debug builds: the battles the screen reader saved (a video and its reads each). They're
/// moved from the App Group into Documents, which shows in Files → On My iPhone → ManGo.
/// Only the newest few are kept, and ones already copied to the Mac are deleted:
/// scripts/pull_battles.sh leaves their names in "pulled.txt".
enum BattleRecordings {
    static let keep = 3

    static var folder: URL { URL.documentsDirectory }

    /// Collects finished recordings and returns how many battles are saved.
    @discardableResult
    static func collect() -> Int {
        let fm = FileManager.default
        if let shared = BroadcastChannel.recordingsFolder,
           let items = try? fm.contentsOfDirectory(at: shared, includingPropertiesForKeys: nil) {
            for f in items where !f.hasDirectoryPath {
                try? fm.moveItem(at: f, to: folder.appendingPathComponent(f.lastPathComponent))
            }
        }
        let pulled = folder.appendingPathComponent("pulled.txt")
        if let names = try? String(contentsOf: pulled, encoding: .utf8) {
            for name in names.split(whereSeparator: \.isNewline).map(String.init) {
                try? fm.removeItem(at: folder.appendingPathComponent(name + ".mp4"))
                try? fm.removeItem(at: folder.appendingPathComponent(name + ".reads.jsonl"))
            }
            try? fm.removeItem(at: pulled)
        }
        // Named by when they started, so newest sorts first.
        let videos = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mp4" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in videos.dropFirst(keep) {
            try? fm.removeItem(at: old)
            try? fm.removeItem(at: old.deletingPathExtension().appendingPathExtension("reads.jsonl"))
        }
        return min(videos.count, keep)
    }
}
#endif
