import CoreVideo
import Foundation

/// How much the screen changed since the last frame, in three areas: where their Pokémon stands
/// (upper right), where yours does (lower left), and the whole battle between the name boxes and
/// your buttons. Each is the mean change in brightness (0-1) over a sparse grid of points. Each
/// fast move makes the screen pulse (the Pokémon lunging, the attack, its hit), so the pulses
/// while play runs can show how long their fast move is: Bite's every 0.5s, not Astonish's 1.5s.
///
/// Measured on every frame the phone gets (about 30 a second; a recording keeps about 11) and
/// saved with each read as `motionTrace`. Not yet used to count: it's recorded so its rhythm can
/// be checked against battles whose fast moves are known.
public struct ScreenMotion: Sendable {
    /// x and y ranges as fractions of the screen.
    public static let areas: [(x: ClosedRange<Double>, y: ClosedRange<Double>)] = [
        (0.5...1.0, 0.1875...0.5625),   // theirs
        (0.0...0.625, 0.5...0.9375),    // yours
        (0.0...1.0, 0.1875...0.9375),   // all
    ]
    static let columns = 24, rows = 48
    static let top = 0.1875, bottom = 0.9375
    /// Which areas each grid point is in, by its index.
    static let membership: [[Int]] = (0..<rows).flatMap { j in
        (0..<columns).map { i in
            let p = point(i, j)
            return areas.indices.filter { areas[$0].x.contains(p.x) && areas[$0].y.contains(p.y) }
        }
    }

    private var last: [Double] = []

    public init() {}

    static func point(_ i: Int, _ j: Int) -> (x: Double, y: Double) {
        ((Double(i) + 0.5) / Double(columns), top + (Double(j) + 0.5) / Double(rows) * (bottom - top))
    }

    /// The change since the last frame measured, per area, or nil on the first frame (or one
    /// that couldn't be read, which also starts over).
    public mutating func measure(in pixels: CVPixelBuffer) -> [Double]? {
        guard let lumas = ScreenPixels.withSampler(pixels, { _, sample in Self.lumas(sample) }) ?? nil else {
            last = []
            return nil
        }
        defer { last = lumas }
        guard last.count == lumas.count else { return nil }
        var sums = [Double](repeating: 0, count: Self.areas.count)
        var counts = [Double](repeating: 0, count: Self.areas.count)
        for k in lumas.indices {
            let change = abs(lumas[k] - last[k])
            for a in Self.membership[k] { sums[a] += change; counts[a] += 1 }
        }
        return zip(sums, counts).map { $0 / max(1, $1) / 255 }
    }

    static func lumas(_ sample: NameBoxBalls.Sampler) -> [Double]? {
        var out: [Double] = []
        out.reserveCapacity(rows * columns)
        for j in 0..<rows {
            for i in 0..<columns {
                let p = point(i, j)
                guard let c = sample(p.x, p.y) else { return nil }
                out.append(0.299 * c.r + 0.587 * c.g + 0.114 * c.b)
            }
        }
        return out
    }
}

/// The colors where their Pokémon stands (`ScreenMotion.areas[0]`), as shares of a sparse grid of
/// points: 12 hues (30 degrees each, from red) of vivid points (saturation >= 0.3, brightness >=
/// 0.2), then dark (brightness < 0.2) and three greys (saturation < 0.3: brightness below 0.45,
/// below 0.75, above). Forms sharing a name can differ in color: Alolan Ninetales is white and
/// icy blue, Ninetales gold. Saved with each read as `theirColors`; not yet used to count.
public enum TheirColors {
    static let columns = 20, rows = 24

    public static func measure(in pixels: CVPixelBuffer) -> [Double]? {
        ScreenPixels.withSampler(pixels) { _, sample in shares(sample) } ?? nil
    }

    static func shares(_ sample: NameBoxBalls.Sampler) -> [Double]? {
        let area = ScreenMotion.areas[0]
        var counts = [Double](repeating: 0, count: 16)
        for j in 0..<rows {
            for i in 0..<columns {
                let x = area.x.lowerBound + (Double(i) + 0.5) / Double(columns) * (area.x.upperBound - area.x.lowerBound)
                let y = area.y.lowerBound + (Double(j) + 0.5) / Double(rows) * (area.y.upperBound - area.y.lowerBound)
                guard let c = sample(x, y) else { return nil }
                counts[bin(r: c.r / 255, g: c.g / 255, b: c.b / 255)] += 1
            }
        }
        return counts.map { $0 / Double(rows * columns) }
    }

    static func bin(r: Double, g: Double, b: Double) -> Int {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        let s = mx > 0 ? d / mx : 0
        if mx < 0.2 { return 12 }
        if s < 0.3 { return mx < 0.45 ? 13 : mx < 0.75 ? 14 : 15 }
        var h: Double
        if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        if h < 0 { h += 6 }
        return min(11, Int(h * 60 / 30))
    }
}
