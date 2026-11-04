import Foundation

/// Your own fast moves landing, read from your charged move buttons' fill on every frame:
/// each one raises your energy, so the buttons fill a step (until they're full). Your fast
/// moves end on turn boundaries, so they're the battle's clock: after a restart both sides
/// start fast moves on the same turn, so your first lands exactly one of your fast moves after
/// it. (221337: your Mud Slap landed 0.9s after ManGo's restart time, so the battle had restarted
/// earlier, and Shadow Greninja's Water Shuriken, also 3 turns, finished with it and sneaked
/// another on your charged move.)
public enum YourFastMoves {
    /// A level holds when 3 frames in a row are within this of each other.
    static let steady = 0.015
    /// A landing raises a button's fill by at least this much...
    static let minimumStep = 0.03
    /// ...from a level that held at least this long.
    static let heldBefore: TimeInterval = 0.15

    /// When your fast moves landed in `samples` ([time, left fill, right fill], oldest first):
    /// where the buttons' fill starts rising from one steady level to a higher one. A level
    /// is steady over 3 frames, and must have held a moment before it rises: a single-frame
    /// glitch can't hold one, and neither can the buttons fading in. Every button that isn't full
    /// (or empty: empty and hidden look the same) and reads clearly has to rise together, as your
    /// energy does: an effect can cover one (Shadow Greninja's battle, 9:45).
    public static func landings(in samples: [[Double]]) -> [TimeInterval] {
        let samples = samples.filter { $0.count == 3 }
        guard samples.count >= 3 else { return [] }
        var rises: [[TimeInterval]] = [[], []]
        var levels: [[(since: TimeInterval, level: Double)]] = [[], []]
        var steadyAt: [[TimeInterval]] = [[], []]
        for button in 1...2 {
            var level: (since: TimeInterval, value: Double)?
            for i in 2..<samples.count {
                let values = [samples[i - 2][button], samples[i - 1][button], samples[i][button]]
                guard values.max()! - values.min()! <= steady else { continue }
                steadyAt[button - 1].append(samples[i][0])
                let held = values.sorted()[1]
                if let from = level, abs(held - from.value) <= steady { continue }
                if let from = level, from.value > 0.02, held >= from.value + minimumStep {
                    // The rise began at the earliest frame, going back, still above the old level.
                    var start = i - 2
                    while start > 0, samples[start - 1][button] > from.value + steady { start -= 1 }
                    if samples[start][0] - from.since >= heldBefore { rises[button - 1].append(samples[start][0]) }
                }
                level = (samples[i - 2][0], held)
                levels[button - 1].append((samples[i - 2][0], held))
            }
        }
        func level(_ b: Int, before t: TimeInterval) -> Double? { levels[b].last { $0.since < t }?.level }
        var found: [TimeInterval] = []
        for b in 0...1 {
            for t in rises[b] {
                let other = 1 - b
                let together = rises[other].contains { abs($0 - t) <= 0.15 }
                // The other button vetoes it only if it could rise and reads clearly just after.
                let otherCanRise = level(other, before: t).map { $0 > 0.02 && $0 < 0.97 } ?? false
                let otherReadable = steadyAt[other].contains { $0 > t && $0 < t + 0.4 }
                if together || !otherCanRise || !otherReadable { found.append(t) }
            }
        }
        var merged: [TimeInterval] = []
        for t in found.sorted() where merged.last.map({ t - $0 > 0.25 }) ?? true { merged.append(t) }
        return merged
    }

    /// Your fast move's length in turns from the gaps between landings, if most of them agree.
    public static func turns(fromGaps gaps: [TimeInterval]) -> Int? {
        let rounded = gaps.compactMap { gap -> Int? in
            let turns = (gap / turnDuration).rounded()
            return (1...5).contains(Int(turns)) && abs(gap - turns * turnDuration) <= 0.15 ? Int(turns) : nil
        }
        guard rounded.count >= 2 else { return nil }
        let counts = Dictionary(grouping: rounded, by: { $0 }).mapValues(\.count)
        guard let (turns, n) = counts.max(by: { $0.value < $1.value }), n * 3 >= rounded.count * 2 else { return nil }
        return turns
    }
}
