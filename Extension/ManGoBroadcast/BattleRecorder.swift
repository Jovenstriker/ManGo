#if DEBUG
import AVFoundation
import PvPCore
import QuartzCore

/// Debug builds only: saves each battle as a video plus every read the screen reader made,
/// timed to the video, so a wrong count can be replayed exactly as the phone saw it.
///
/// A recording starts with the first frame while the reader isn't idle and ends when it
/// goes idle (the battle ended) or the broadcast stops. It's written to
/// `BroadcastChannel.recordingsFolder`/in progress, then moved up a level for the app to
/// collect. Half size at 15 frames a second: enough to read the text and HP bars, about
/// 50 MB a battle.
final class BattleRecorder {
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var reads: FileHandle?
    private var files: [URL] = []
    /// When the video's first frame arrived; read times are saved relative to it.
    private var startedAt: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0

    private static let frameInterval: CFTimeInterval = 1.0 / 15
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    func append(_ sampleBuffer: CMSampleBuffer, at now: CFTimeInterval, idle: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if idle {
            finishLocked()
            return
        }
        if writer == nil { start(sampleBuffer, at: now) }
        guard let writer, let input, writer.status == .writing,
              now - lastFrame >= Self.frameInterval, input.isReadyForMoreMediaData
        else { return }
        if input.append(sampleBuffer) { lastFrame = now }
    }

    func log(_ read: ScreenRead) {
        lock.lock()
        defer { lock.unlock() }
        guard let reads, read.time >= startedAt else { return }
        var shifted = ScreenRead(time: read.time - startedAt, lines: read.lines)
        shifted.readSeconds = read.readSeconds
        shifted.opponentAlive = read.opponentAlive
        guard var line = try? JSONEncoder().encode(shifted) else { return }
        line.append(0x0A)
        reads.write(line)
    }

    func finish() {
        lock.lock()
        finishLocked()
        lock.unlock()
    }

    private func start(_ sampleBuffer: CMSampleBuffer, at now: CFTimeInterval) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let done = BroadcastChannel.recordingsFolder
        else { return }
        let folder = done.appendingPathComponent("in progress", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "battle-" + Self.stamp.string(from: .now)
        let video = folder.appendingPathComponent(name + ".mp4")
        let readsURL = folder.appendingPathComponent(name + ".reads.jsonl")
        guard let writer = try? AVAssetWriter(outputURL: video, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: CVPixelBufferGetWidth(pixels) / 4 * 2,
            AVVideoHeightKey: CVPixelBufferGetHeight(pixels) / 4 * 2,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_500_000,
                AVVideoExpectedSourceFrameRateKey: 15,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return }
        writer.add(input)
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        FileManager.default.createFile(atPath: readsURL.path, contents: nil)
        self.writer = writer
        self.input = input
        reads = try? FileHandle(forWritingTo: readsURL)
        files = [video, readsURL]
        startedAt = now
        lastFrame = 0
    }

    private func finishLocked() {
        guard let writer, let input else { return }
        self.writer = nil
        self.input = nil
        try? reads?.close()
        reads = nil
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        _ = finished.wait(timeout: .now() + 5)
        let fm = FileManager.default
        guard writer.status == .completed, let folder = BroadcastChannel.recordingsFolder else {
            for f in files { try? fm.removeItem(at: f) }
            return
        }
        for f in files { try? fm.moveItem(at: f, to: folder.appendingPathComponent(f.lastPathComponent)) }
    }
}
#endif
