import CoreGraphics
import CoreVideo

/// Your Pokémon's HP bar, which floats above it on the left. Its fill shrinks only when
/// damage lands (in the June 2026 battle system), so the first drop after GO is the
/// opponent's first fast move landing.
///
/// The bar moves with your Pokémon. Its pale rectangular outline and dark/colored
/// interior identify it; color alone would mistake sprites for HP. Fill is measured
/// inside that outline as a fraction of screen width.
public enum YourHPBar {
    /// Where your bar can be: x 0–0.5, y 0.2–0.7 of a portrait screen.
    static let area = CGRect(x: 0.01, y: 0.2, width: 0.49, height: 0.5)

    static func isFill(_ p: (r: Double, g: Double, b: Double)) -> Bool {
        let teal = p.g > 170 && p.b > 120 && p.r < 120 && p.g - p.r > 90
        let yellow = p.r > 200 && p.g > 170 && p.b < 110
        let red = p.r > 180 && p.g < 150 && p.b < 150 && p.r - max(p.g, p.b) > 60
        return teal || yellow || red
    }

    /// The player's bar spans a predictable part of the left half. Verify both pale outlines and
    /// the colored/dark interior; a Pokémon's body is not a health measurement.
    private static func hasOutline(atY y: Double, aspect: Double, sample: NameBoxBalls.Sampler, width: Int) -> Bool {
        let halfHeight = 0.014 / aspect
        func pale(_ p: (r: Double, g: Double, b: Double)) -> Bool {
            min(p.r, p.g, p.b) > 150 && max(p.r, p.g, p.b) - min(p.r, p.g, p.b) < 65
        }
        let xs = [0.065, 0.10, 0.16, 0.22, 0.28, 0.335]
        func border(_ row: Double) -> Bool {
            xs.filter { x in
                (-2...2).contains { dy in
                    sample(x, row + Double(dy) / (Double(width) * aspect)).map(pale) ?? false
                }
            }.count >= 5
        }
        guard border(y - halfHeight), border(y + halfHeight) else { return false }
        return xs.filter { x in
            guard let p = sample(x, y) else { return false }
            return isFill(p) || max(p.r, p.g, p.b) < 100
        }.count >= 5
    }

    public static func locate(aspect: Double, sample: NameBoxBalls.Sampler, width: Int) -> Double? {
        let step = 2 / (Double(width) * aspect)
        var y = area.minY
        while y <= area.maxY {
            if hasOutline(atY: y, aspect: aspect, sample: sample, width: width) { return y }
            y += step
        }
        return nil
    }

    /// Only the interior of the verified player bar is measured. Preserve small red
    /// slivers and avoid colored sprites elsewhere on the same row.
    public static func fill(atY y: Double, aspect: Double, sample: NameBoxBalls.Sampler, width: Int, height: Int) -> Double {
        let step = 1 / Double(width)
        func pale(_ p: (r: Double, g: Double, b: Double)) -> Bool {
            min(p.r, p.g, p.b) > 150 && max(p.r, p.g, p.b) - min(p.r, p.g, p.b) < 65
        }
        // The bar slides horizontally during attack animations. Find its actual
        // outline endpoints rather than interpreting the gap before it as zero HP.
        var best: (start: Double, end: Double)?
        for dy in -2...2 {
            let row = y - 0.014 / aspect + Double(dy) / Double(height)
            var start: Double?, last = 0.0, x = 0.035
            while x <= 0.45 {
                if sample(x, row).map(pale) == true {
                    if start == nil { start = x }
                    last = x
                } else if let first = start, x - last > 3 * step {
                    let length = last - first
                    if (0.23...0.34).contains(length), length > (best.map { $0.end - $0.start } ?? 0) { best = (first, last) }
                    start = nil
                }
                x += step
            }
        }
        guard let edges = best else { return 0 }
        func length(_ row: Double) -> Double {
            var x = edges.start + 0.004, bestRun = 0.0, start: Double?, last = 0.0
            while x <= edges.end - 0.004 {
                if let p = sample(x, row), isFill(p) {
                    if start == nil { start = x }
                    last = x
                    bestRun = max(bestRun, last - start! + step)
                } else if start != nil, x - last > 3 * step { start = nil }
                x += step
            }
            return bestRun
        }
        return (-2...2).map { length(y + Double($0) / Double(height)) }.max() ?? 0
    }

    /// From a decoded video frame (for screen-log): finds the bar and measures it.
    public static func measure(in image: CGImage) -> (y: Double, fill: Double)? {
        ScreenPixels.withSampler(image, region: area.insetBy(dx: 0, dy: -0.01)) { aspect, sample in
            guard let y = locate(aspect: aspect, sample: sample, width: image.width) else { return nil }
            return (y, fill(atY: y, aspect: aspect, sample: sample, width: image.width, height: image.height))
        } ?? nil
    }

    /// On the phone: finds the bar (`y` nil) or measures it at a known row.
    public static func measure(in pixels: CVPixelBuffer, atY knownY: Double?) -> (y: Double, fill: Double)? {
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        return ScreenPixels.withSampler(pixels) { aspect, sample in
            let verified = knownY.flatMap { hasOutline(atY: $0, aspect: aspect, sample: sample, width: w) ? $0 : nil }
            guard let y = verified ?? locate(aspect: aspect, sample: sample, width: w) else { return nil }
            return (y, fill(atY: y, aspect: aspect, sample: sample, width: w, height: h))
        } ?? nil
    }
}
