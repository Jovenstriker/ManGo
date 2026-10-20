import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

/// A line of text found on screen. `box` is normalized (0...1) with a top-left origin.
public struct RecognizedText: Codable, Sendable, Equatable {
    public let text: String
    public let box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// Reads text from battle screenshots or screen recording frames with Vision.
public enum ScreenTextReader {
    /// Where the opponent's name sits: the top-right of the battle screen.
    /// Normalized, top-left origin. Your own Pokémon's name is top-left, so it's excluded.
    public static let opponentNameRegion = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.3)
    public static let fullScreen = CGRect(x: 0, y: 0, width: 1, height: 1)

    public static func recognize(
        in image: CGImage,
        region: CGRect = opponentNameRegion
    ) throws -> [RecognizedText] {
        try perform(VNImageRequestHandler(cgImage: image, orientation: .up), region: region)
    }

    public static func recognize(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up,
        region: CGRect = opponentNameRegion
    ) throws -> [RecognizedText] {
        try perform(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation), region: region)
    }

    private static func perform(_ handler: VNImageRequestHandler, region: CGRect) throws -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false  // Pokémon names aren't dictionary words
        request.minimumTextHeight = 0.007  // battle text is ≥1% of the screen height; skip smaller
        // Vision's region of interest has a bottom-left origin.
        request.regionOfInterest = CGRect(
            x: region.minX, y: 1 - region.maxY, width: region.width, height: region.height
        )
        try handler.perform([request])

        return (request.results ?? []).compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            // Boxes are relative to the region of interest; map back to the full image.
            let b = obs.boundingBox
            let full = CGRect(
                x: region.minX + b.minX * region.width,
                y: region.minY + (1 - b.maxY) * region.height,
                width: b.width * region.width,
                height: b.height * region.height
            )
            return RecognizedText(text: candidate.string, box: full)
        }
    }
}

/// Everything read from one screen frame, and when it was captured
/// (`CACurrentMediaTime()` in the extension, or seconds into a recording).
public struct ScreenRead: Codable, Sendable, Equatable {
    public let time: TimeInterval
    public let lines: [RecognizedText]

    public init(time: TimeInterval, lines: [RecognizedText]) {
        self.time = time
        self.lines = lines
    }
}
