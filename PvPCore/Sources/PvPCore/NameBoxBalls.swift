import CoreGraphics
import CoreVideo

/// How many Pokémon the opponent has left, from the 3 pokéballs in their name box (top
/// right): red while a Pokémon is alive, a dull red-gray once one has fainted. The box is
/// hidden during charged moves and ManGo's card can cover it; then there's no count.
///
/// A faint darkens the leftmost red ball, whichever Pokémon it was, so only the number of
/// red balls means anything.
public enum NameBoxBalls {
    /// Ball centers as fractions of a portrait screen (iPhone), and their radius as a
    /// fraction of its width. Calibrated on phone recordings.
    static let centers: [(x: Double, y: Double)] = [(0.839, 0.124), (0.896, 0.124), (0.950, 0.124)]
    static let radius = 0.010

    /// Mean color of a ball, 0–255 per channel, from `sample(x, y)` with x and y as
    /// fractions of the screen.
    public typealias Sampler = (_ x: Double, _ y: Double) -> (r: Double, g: Double, b: Double)?

    /// Red balls, if all three read clearly as red (alive) or dull red-gray (fainted).
    public static func alive(aspect: Double, sample: Sampler) -> Int? {
        var alive = 0
        for c in centers {
            var sum = (r: 0.0, g: 0.0, b: 0.0), n = 0.0
            for i in -4...4 {
                for j in -4...4 where i * i + j * j <= 16 {
                    let x = c.x + Double(i) / 4 * radius
                    let y = c.y + Double(j) / 4 * radius / aspect
                    guard let p = sample(x, y) else { return nil }
                    sum = (sum.r + p.r, sum.g + p.g, sum.b + p.b)
                    n += 1
                }
            }
            let (r, g, b) = (sum.r / n, sum.g / n, sum.b / n)
            if r > 170, g < 100, b < 110 {
                alive += 1
            } else if (60...140).contains(r), g < 110, b < 110, r - g < 50 {
                continue  // fainted
            } else {
                return nil  // not a ball: sky, the card, a charged move
            }
        }
        return alive > 0 ? alive : nil
    }

    /// From a screen frame as delivered to the broadcast extension (BGRA or 4:2:0 YCbCr).
    public static func alive(in pixels: CVPixelBuffer) -> Int? {
        ScreenPixels.withSampler(pixels) { aspect, sample in alive(aspect: aspect, sample: sample) } ?? nil
    }

    /// From a decoded video frame (for screen-log).
    public static func alive(in image: CGImage) -> Int? {
        // Only the name box's corner is drawn: x 0.8–1, y 0.1–0.15.
        ScreenPixels.withSampler(image, region: CGRect(x: 0.8, y: 0.10, width: 0.2, height: 0.05)) { aspect, sample in
            alive(aspect: aspect, sample: sample)
        } ?? nil
    }
}
