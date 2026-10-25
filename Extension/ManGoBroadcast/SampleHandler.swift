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
///
/// Between battles (the app sets `BroadcastChannel.idleSince` when one ends) it reads only
/// every 2 seconds, enough to see the next one start, and after 3 minutes with no new
/// battle it ends the broadcast. Debug builds also save each battle (`BattleRecorder`).
final class SampleHandler: RPBroadcastSampleHandler {
    private let interval: CFTimeInterval = 0.25
    private let queue = DispatchQueue(label: "com.jovenstriker.mango.read", qos: .userInitiated)
    private let lock = NSLock()
    private var lastRead: CFTimeInterval = 0
    private var busy = false
    private var finished = false
    /// `BroadcastChannel.idleSince`, checked at most 4 times a second.
    private var idleSince: TimeInterval?
    private var idleCheckedAt: CFTimeInterval = -.infinity
    /// Your buttons' fill on each frame since the last read: [time, left, right].
    private var fillTrace: [[Double]] = []
    /// Your HP bar on each frame since the last read: [time, fill]. Its row is found twice
    /// a second (it moves with your Pokémon); measuring it is cheap.
    private var hpTrace: [[Double]] = []
    private var hpBarY: Double?
    private var hpBarFoundAt: CFTimeInterval = -.infinity
    #if DEBUG
    private let recorder = BattleRecorder()
    #endif

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // A new broadcast reads at full speed, even if the last one ended idle.
        BroadcastChannel.idleSince = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        if now - idleCheckedAt >= interval {
            idleSince = BroadcastChannel.idleSince
            idleCheckedAt = now
        }
        let idle = idleSince != nil
        #if DEBUG
        let record = !finished
        lock.unlock()
        if record { recorder.append(sampleBuffer, at: now, idle: idle) }
        lock.lock()
        #endif
        // The buttons are checked on every frame during a battle: a few thousand pixels, no
        // text reading, so your fast moves can be timed to the frame.
        if !idle, !finished {
            lock.unlock()
            let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
            let fill = pixels.flatMap { ChargeButtons.fill(in: $0) }
            let relocate = now - hpBarFoundAt > 0.5
            let hp = pixels.flatMap { YourHPBar.measure(in: $0, atY: relocate ? nil : hpBarY) }
            let width = pixels.map { Double(CVPixelBufferGetWidth($0)) } ?? 0
            lock.lock()
            if let fill {
                fillTrace.append([now, fill[0], fill[1]])
                if fillTrace.count > 240 { fillTrace.removeFirst(fillTrace.count - 240) }
            }
            if relocate { hpBarFoundAt = now; hpBarY = hp?.y }
            if let hp {
                hpTrace.append([now, hp.fill, width])
                if hpTrace.count > 240 { hpTrace.removeFirst(hpTrace.count - 240) }
            }
        }
        guard !busy, !finished, now - lastRead >= interval else {
            lock.unlock()
            return
        }
        if let idle = idleSince {
            if now - idle > BroadcastChannel.idleStopAfter {
                finished = true
                lock.unlock()
                #if DEBUG
                recorder.finish()
                #endif
                finishBroadcastWithError(NSError(domain: "ManGo", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "No new battle for 3 minutes, so ManGo stopped reading the screen. Tap Screen reader in ManGo to start again.",
                ]))
                return
            }
            if now - lastRead < BroadcastChannel.idleInterval {
                lock.unlock()
                return
            }
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
            let started = CACurrentMediaTime()
            let lines = autoreleasepool {
                (try? ScreenTextReader.recognize(in: pixels, orientation: orientation, region: ScreenTextReader.fullScreen)) ?? []
            }
            var read = ScreenRead(time: now, lines: lines)
            read.readSeconds = CACurrentMediaTime() - started
            read.opponentAlive = NameBoxBalls.alive(in: pixels)
            read.buttonFill = ChargeButtons.fill(in: pixels)
            self?.lock.lock()
            read.fillTrace = self?.fillTrace
            self?.fillTrace = []
            read.hpTrace = self?.hpTrace
            self?.hpTrace = []
            self?.lock.unlock()
            if let memory = MemoryUsage.current() {
                read.memoryMB = memory.now
                read.peakMemoryMB = memory.peak
            }
            BroadcastChannel.send(read)
            #if DEBUG
            self?.recorder.log(read)
            #endif
        }
    }

    override func broadcastFinished() {
        lock.lock()
        finished = true
        lock.unlock()
        #if DEBUG
        recorder.finish()
        #endif
    }

    private func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
              let o = CGImagePropertyOrientation(rawValue: n.uint32Value)
        else { return .up }
        return o
    }
}
