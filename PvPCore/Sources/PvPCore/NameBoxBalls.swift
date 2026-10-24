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
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let format = CVPixelBufferGetPixelFormatType(pixels)
        let sample: Sampler
        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            sample = { x, y in
                let px = Int(x * Double(w)), py = Int(y * Double(h))
                guard (0..<w).contains(px), (0..<h).contains(py) else { return nil }
                let o = py * row + px * 4
                return (Double(bytes[o + 2]), Double(bytes[o + 1]), Double(bytes[o]))
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 0),
                  let cBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 1) else { return nil }
            let yRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0), cRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
            let yBytes = yBase.assumingMemoryBound(to: UInt8.self), cBytes = cBase.assumingMemoryBound(to: UInt8.self)
            let video = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            sample = { x, y in
                let px = Int(x * Double(w)), py = Int(y * Double(h))
                guard (0..<w).contains(px), (0..<h).contains(py) else { return nil }
                var luma = Double(yBytes[py * yRow + px])
                if video { luma = (luma - 16) * 255 / 219 }
                let co = (py / 2) * cRow + (px / 2) * 2
                let cb = Double(cBytes[co]) - 128, cr = Double(cBytes[co + 1]) - 128
                func clamp(_ v: Double) -> Double { min(255, max(0, v)) }
                return (clamp(luma + 1.402 * cr), clamp(luma - 0.344 * cb - 0.714 * cr), clamp(luma + 1.772 * cb))
            }
        default:
            return nil
        }
        return alive(aspect: Double(h) / Double(w), sample: sample)
    }

    /// From a decoded video frame (for screen-log).
    public static func alive(in image: CGImage) -> Int? {
        let w = image.width, h = image.height
        // Only the name box's corner is drawn: x 0.8–1, y 0.1–0.15.
        let crop = CGRect(x: Int(0.8 * Double(w)), y: Int(0.10 * Double(h)), width: w - Int(0.8 * Double(w)), height: Int(0.05 * Double(h)))
        guard let part = image.cropping(to: crop) else { return nil }
        let cw = part.width, ch = part.height
        var bytes = [UInt8](repeating: 0, count: cw * ch * 4)
        guard let ctx = CGContext(data: &bytes, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: cw, height: ch))
        return alive(aspect: Double(h) / Double(w)) { x, y in
            let px = Int(x * Double(w)) - Int(crop.minX), py = Int(y * Double(h)) - Int(crop.minY)
            guard (0..<cw).contains(px), (0..<ch).contains(py) else { return nil }
            let o = py * cw * 4 + px * 4
            return (Double(bytes[o]), Double(bytes[o + 1]), Double(bytes[o + 2]))
        }
    }
}
