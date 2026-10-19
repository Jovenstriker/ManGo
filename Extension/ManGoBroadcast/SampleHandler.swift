import CoreMedia
import PvPCore
import QuartzCore
import ReplayKit

/// Runs while you screen-record with "ManGo Screen Reader". Twice a second it reads
/// the top-right of the screen (the opponent's name) and hands the text to the app.
/// Broadcast extensions are limited to ~50 MB, so frames are processed one at a
/// time on the delivery queue and never retained.
final class SampleHandler: RPBroadcastSampleHandler {
    private let interval: CFTimeInterval = 0.5
    private var lastRead: CFTimeInterval = 0

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }
        let now = CACurrentMediaTime()
        guard now - lastRead >= interval, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastRead = now

        let lines = autoreleasepool {
            (try? ScreenTextReader.recognize(in: pixels, orientation: orientation(of: sampleBuffer))) ?? []
        }
        BroadcastChannel.send(lines)
    }

    private func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
              let o = CGImagePropertyOrientation(rawValue: n.uint32Value)
        else { return .up }
        return o
    }
}
