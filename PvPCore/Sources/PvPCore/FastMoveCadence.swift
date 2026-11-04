import Foundation

/// Reads a repeated damage rhythm from a verified HP bar. It deliberately does not
/// count attacks when the bar vanishes, jumps up on a switch, or only tiny pixels flicker.
struct FastMoveCadence: Sendable {
    private var recent: [(time: TimeInterval, pixels: Double)] = []
    private var level: Double?
    private var lastSample: TimeInterval?
    private var hits: [TimeInterval] = []

    mutating func observe(time: TimeInterval, pixels: Double) -> TimeInterval? {
        guard time.isFinite, pixels.isFinite, pixels > 0 else { return nil }
        if let lastSample, time <= lastSample { return nil }
        if let lastSample, time - lastSample > 0.8 { recent = []; level = nil; hits = [] }
        lastSample = time
        recent.append((time, pixels))
        if recent.count > 3 { recent.removeFirst() }
        guard recent.count == 3 else { return nil }
        let value = recent.map(\.pixels).sorted()[1]
        guard let before = level else { level = value; return nil }
        if value > before + 4 { level = value; hits = []; return nil }
        guard before - value >= 3 else { return nil }
        level = value
        let hit = recent[1].time
        if let last = hits.last, hit - last < 0.35 { hits = []; return nil }
        hits.append(hit)
        if hits.count > 4 { hits.removeFirst() }
        guard hits.count >= 3 else { return nil }
        let intervals = zip(hits.dropFirst(), hits).map { $0 - $1 }
        let median = intervals.sorted()[intervals.count / 2]
        guard intervals.allSatisfy({ abs($0 - median) <= 0.2 }) else { return nil }
        return median
    }
}
