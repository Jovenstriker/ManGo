import CoreGraphics
import CoreVideo

/// Reads pixel colors from a screen frame, by position as fractions of the screen, for the
/// readers that look at shapes rather than text (pokéballs, charged move buttons).
enum ScreenPixels {
    /// Calls `body` with the frame's height/width and a sampler returning 0–255 RGB at
    /// (x, y), or nil off the frame. Nil if the pixel format isn't supported.
    static func withSampler<T>(_ pixels: CVPixelBuffer, _ body: (Double, NameBoxBalls.Sampler) -> T) -> T? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let format = CVPixelBufferGetPixelFormatType(pixels)
        let aspect = Double(h) / Double(w)
        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            return body(aspect) { x, y in
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
            return body(aspect) { x, y in
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
    }

    /// The same for a decoded video frame. Only `region` (fractions of the frame) is
    /// decoded; samples outside it are nil.
    static func withSampler<T>(_ image: CGImage, region: CGRect, _ body: (Double, NameBoxBalls.Sampler) -> T) -> T? {
        let w = image.width, h = image.height
        let crop = CGRect(x: Int(region.minX * Double(w)), y: Int(region.minY * Double(h)),
                          width: Int(region.width * Double(w)), height: Int(region.height * Double(h)))
        guard let part = image.cropping(to: crop) else { return nil }
        let cw = part.width, ch = part.height
        var bytes = [UInt8](repeating: 0, count: cw * ch * 4)
        guard let ctx = CGContext(data: &bytes, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: cw, height: ch))
        return body(Double(h) / Double(w)) { x, y in
            let px = Int(x * Double(w)) - Int(crop.minX), py = Int(y * Double(h)) - Int(crop.minY)
            guard (0..<cw).contains(px), (0..<ch).contains(py) else { return nil }
            let o = py * cw * 4 + px * 4
            return (Double(bytes[o]), Double(bytes[o + 1]), Double(bytes[o + 2]))
        }
    }
}
