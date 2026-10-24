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
    public static let fullScreen = CGRect(x: 0, y: 0, width: 1, height: 1)

    public static func recognize(
        in image: CGImage,
        region: CGRect = fullScreen
    ) throws -> [RecognizedText] {
        try perform(VNImageRequestHandler(cgImage: image, orientation: .up), region: region)
    }

    public static func recognize(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up,
        region: CGRect = fullScreen
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
    /// The screen reader's memory when it made this read, in MB: now and the peak so far.
    public var memoryMB: Double?
    public var peakMemoryMB: Double?
    /// How long reading the text took, in seconds.
    public var readSeconds: Double?
    /// Red pokéballs in the opponent's name box (Pokémon they have left), when it's visible.
    public var opponentAlive: Int?
    /// How full your charged move buttons are, left then right (0–1): see ChargeButtons.
    public var buttonFill: [Double]?

    public init(time: TimeInterval, lines: [RecognizedText]) {
        self.time = time
        self.lines = lines
    }
}
