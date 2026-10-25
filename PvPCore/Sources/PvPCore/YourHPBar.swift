import CoreGraphics
import CoreVideo

/// Your Pokémon's HP bar, which floats above it on the left. Its fill shrinks only when
/// damage lands (in the June 2026 battle system), so the first drop after GO is the
/// opponent's first fast move landing.
///
/// The bar moves with your Pokémon, so `locate` finds its row: the longest run of the
/// bar's colors (green-teal, yellow, red) in the left half. `fill` then measures that row
/// (and the rows next to it) as a fraction of the screen's width.
public enum YourHPBar {
    /// Where your bar can be: x 0–0.5, y 0.2–0.7 of a portrait screen.
    static let area = CGRect(x: 0.01, y: 0.2, width: 0.49, height: 0.5)

    static func isFill(_ p: (r: Double, g: Double, b: Double)) -> Bool {
        let teal = p.g > 170 && p.b > 120 && p.r < 120 && p.g - p.r > 90
        let yellow = p.r > 200 && p.g > 170 && p.b < 110
        let red = p.r > 190 && p.g < 90 && p.b < 90
        return teal || yellow || red
    }

    /// The longest run of fill along row `y`, as a fraction of the width, sampled every
    /// `step` of the width. Gaps of a sample or two (a glint, a number) are bridged.
    static func run(atY y: Double, step: Double, sample: NameBoxBalls.Sampler) -> Double {
        var best = 0.0, start: Double?, lastFill = -1.0
        var x = area.minX
        while x <= area.maxX {
            if let p = sample(x, y), isFill(p) {
                if start == nil || x - lastFill > 3 * step { start = x }
                lastFill = x
                best = max(best, x - start! + step)
            }
            x += step
        }
        return best
    }

    /// The row of your HP bar, if one is on screen: the row with the longest fill run.
    public static func locate(aspect: Double, sample: NameBoxBalls.Sampler, width: Int) -> Double? {
        let px = 1 / Double(width)
        var best = (y: 0.0, length: 0.0)
        var y = area.minY
        while y <= area.maxY {
            let length = run(atY: y, step: 3 * px, sample: sample)
            if length > best.length { best = (y, length) }
            y += 2 * px / aspect  // every other pixel row
        }
        // A bar is at least a sixth of the screen wide when full; a damaged one is shorter
        // but still has its outline, so anything over 2% counts.
        return best.length > 0.02 ? best.y : nil
    }

    /// How much of the bar is filled at row `y` (±2 pixel rows), as a fraction of the width.
    public static func fill(atY y: Double, aspect: Double, sample: NameBoxBalls.Sampler, width: Int, height: Int) -> Double {
        let px = 1 / Double(width), row = 1 / Double(height)
        return (-2...2).map { run(atY: y + Double($0) * row, step: px, sample: sample) }.max() ?? 0
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
            guard let y = knownY ?? locate(aspect: aspect, sample: sample, width: w) else { return nil }
            return (y, fill(atY: y, aspect: aspect, sample: sample, width: w, height: h))
        } ?? nil
    }
}
