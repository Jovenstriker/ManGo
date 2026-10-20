import CoreMedia
import PvPCore
import QuartzCore
import ReplayKit

/// Runs while you screen-record with "ManGo Screen Reader". Four times a second it
/// reads the text on screen and hands it to the app, stamped with when the frame
/// arrived. Broadcast extensions are limited to ~50 MB, so frames are processed one
/// at a time on the delivery queue and never retained.
final class SampleHandler: RPBroadcastSampleHandler {
    private let interval: CFTimeInterval = 0.25
    private var lastRead: CFTimeInterval = 0

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }
        let now = CACurrentMediaTime()
        guard now - lastRead >= interval, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastRead = now

        let lines = autoreleasepool {
            (try? ScreenTextReader.recognize(
                in: pixels, orientation: orientation(of: sampleBuffer), region: ScreenTextReader.fullScreen
            )) ?? []
        }
        var read = ScreenRead(time: now, lines: lines)
        if let memory = MemoryUsage.current() {
            read.memoryMB = memory.now
            read.peakMemoryMB = memory.peak
        }
        BroadcastChannel.send(read)
    }

    private func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
              let o = CGImagePropertyOrientation(rawValue: n.uint32Value)
        else { return .up }
        return o
    }
}
