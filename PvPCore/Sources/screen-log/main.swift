import AVFoundation
import CoreGraphics
import Foundation
import PvPCore

// Prints the text visible in a battle recording over time, to work out what the
// screen shows during charged moves, switches and faints.
//
//   swift run screen-log <video> [seconds between frames, default 0.25]

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: screen-log <video> [interval]")
    exit(1)
}
let interval = args.count >= 3 ? Double(args[2]) ?? 0.25 : 0.25
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let duration = try await asset.load(.duration).seconds
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

/// Rough screen position: top / middle / bottom and left / center / right.
func zone(_ box: CGRect) -> String {
    let v = box.midY < 0.33 ? "top" : box.midY < 0.66 ? "mid" : "bot"
    let h = box.midX < 0.33 ? "L" : box.midX < 0.66 ? "C" : "R"
    return v + "-" + h
}

var previous = ""
var t = 0.0
while t < duration {
    let image = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    let lines = try ScreenTextReader.recognize(in: image, region: CGRect(x: 0, y: 0, width: 1, height: 1))
    let text = lines
        .sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
        .map { "[\(zone($0.box))] \($0.text)" }
        .joined(separator: "  ")
    // Only print when the visible text changes.
    if text != previous {
        print(String(format: "%7.2fs  ", t) + (text.isEmpty ? "(no text)" : text))
        previous = text
    }
    t += interval
}
