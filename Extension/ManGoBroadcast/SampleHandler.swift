import CoreMedia
import PvPCore
import QuartzCore
import ReplayKit

/// Runs while you screen-record with "ManGo Screen Reader". Four times a second it
/// reads the text on screen and hands it to the app, stamped with when the frame
/// arrived.
///
/// Reading happens on its own queue, one frame at a time, so the callback that iOS
/// delivers frames (and Stop Broadcast) on returns immediately; frames that arrive
/// while a read is in progress are skipped. Broadcast extensions are limited to
/// ~50 MB, so at most one frame is held at a time.
final class SampleHandler: RPBroadcastSampleHandler {
    private let interval: CFTimeInterval = 0.25
    private let queue = DispatchQueue(label: "com.jovenstriker.mango.read", qos: .userInitiated)
    private let lock = NSLock()
    private var lastRead: CFTimeInterval = 0
    private var busy = false
    private var finished = false

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        guard !busy, !finished, now - lastRead >= interval else {
            lock.unlock()
            return
        }
        busy = true
        lastRead = now
        lock.unlock()

        let orientation = orientation(of: sampleBuffer)
        queue.async { [weak self] in
            defer {
                self?.lock.lock()
                self?.busy = false
                self?.lock.unlock()
            }
            guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let lines = autoreleasepool {
                (try? ScreenTextReader.recognize(in: pixels, orientation: orientation, region: ScreenTextReader.fullScreen)) ?? []
            }
            var read = ScreenRead(time: now, lines: lines)
            if let memory = MemoryUsage.current() {
                read.memoryMB = memory.now
                read.peakMemoryMB = memory.peak
            }
            BroadcastChannel.send(read)
        }
    }

    override func broadcastFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    private func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
              let o = CGImagePropertyOrientation(rawValue: n.uint32Value)
        else { return .up }
        return o
    }
}
