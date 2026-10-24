import CoreGraphics
import CoreVideo

/// How full your two charged move buttons are (0–1, left then right). Each fills from the
/// bottom in the move's color as your energy rises, one step per fast move you land
/// (energy gained ÷ the move's cost), and stays full once you can afford the move.
///
/// The level is where the color changes going up from the bottom, measured at the sides
/// of the button since the move's icon sits in the middle. With no edge, a bright button
/// is full and a dark one empty. For about 0.7s after the buttons come back they fade in
/// and the levels jump, so a reading means something only once it holds.
public enum ChargeButtons {
    /// Button centers as fractions of a portrait screen (iPhone), and their radius as a
    /// fraction of its width. Calibrated on phone recordings.
    static let centers: [(x: Double, y: Double)] = [(0.311, 0.890), (0.690, 0.890)]
    static let radius = 0.077
    static let rows = 60

    public static func fill(aspect: Double, sample: NameBoxBalls.Sampler) -> [Double]? {
        var levels: [Double] = []
        for c in centers {
            guard let level = level(at: c, aspect: aspect, sample: sample) else { return nil }
            levels.append(level)
        }
        return levels
    }

    private static func level(at c: (x: Double, y: Double), aspect: Double, sample: NameBoxBalls.Sampler) -> Double? {
        var colors: [(Double, Double, Double)] = []
        for k in 0...rows {
            let v = 1 - 2 * Double(k) / Double(rows)  // 1 at the bottom, -1 at the top
            let y = c.y + v * radius / aspect
            let half = (1 - v * v).squareRoot() * radius
            var r: [Double] = [], g: [Double] = [], b: [Double] = []
            for u in [0.5, 0.6, 0.7, 0.8] {
                for side in [-1.0, 1.0] {
                    guard let p = sample(c.x + side * u * half, y) else { return nil }
                    r.append(p.r); g.append(p.g); b.append(p.b)
                }
            }
            func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
            colors.append((median(r), median(g), median(b)))
        }
        // Skip the outline at the very bottom; the fill's color is the next few rows'.
        let start = 3
        let base = colors[start..<(start + 3)].reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.0 / 3, $0.1 + $1.1 / 3, $0.2 + $1.2 / 3) }
        func distance(_ p: (Double, Double, Double)) -> Double {
            ((p.0 - base.0) * (p.0 - base.0) + (p.1 - base.1) * (p.1 - base.1) + (p.2 - base.2) * (p.2 - base.2)).squareRoot()
        }
        for k in (start + 3)..<(rows - start) where distance(colors[k]) > 45 && distance(colors[min(k + 2, rows)]) > 45 {
            return Double(k) / Double(rows)
        }
        return (base.0 + base.1 + base.2) / 3 > 110 ? 1 : 0
    }

    /// From a screen frame as delivered to the broadcast extension.
    public static func fill(in pixels: CVPixelBuffer) -> [Double]? {
        ScreenPixels.withSampler(pixels) { aspect, sample in fill(aspect: aspect, sample: sample) } ?? nil
    }

    /// From a decoded video frame (for screen-log): only the bottom of the screen is drawn.
    public static func fill(in image: CGImage) -> [Double]? {
        ScreenPixels.withSampler(image, region: CGRect(x: 0, y: 0.78, width: 1, height: 0.2)) { aspect, sample in
            fill(aspect: aspect, sample: sample)
        } ?? nil
    }
}
