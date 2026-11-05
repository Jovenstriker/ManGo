import AVFoundation
import AVKit
import PvPCore
import SwiftUI
import UIKit

/// Shows the tracker in a Picture-in-Picture window over Pokémon GO.
///
/// iOS only allows PiP for video, so the overlay is drawn into pixel buffers a few
/// times a second and fed to an `AVSampleBufferDisplayLayer`. While PiP is up the
/// app keeps running in the background, so screen reads keep arriving and the clock
/// keeps being rendered.
@MainActor @Observable
final class OverlayController: NSObject {
    static let size = CGSize(width: 600, height: 340)

    let displayLayer = AVSampleBufferDisplayLayer()
    private(set) var isActive = false
    private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()

    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var model: TrackerModel?
    /// Whether the screen reader was sending reads at the last render.
    @ObservationIgnored private var wasReading = false
    /// No read for this long means the screen reader stopped (between battles reads still
    /// come every 2s).
    static let readingTimeout: TimeInterval = 5

    func attach(_ model: TrackerModel) {
        guard self.model == nil else { return }
        self.model = model
        displayLayer.videoGravity = .resizeAspect

        // PiP needs a playback audio session. It mixes with other audio, so your music and
        // Pokémon GO's sound keep playing (ManGo's card plays none of its own).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        if isSupported {
            let pip = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self))
            // Pops out when you leave the app, but only while the screen reader is running.
            pip.canStartPictureInPictureAutomaticallyFromInline = false
            pip.requiresLinearPlayback = true
            pip.delegate = self
            self.pip = pip
        }

        render()
        // Scheduled on the main run loop, so it fires on the main actor.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    func toggle() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    private func render() {
        guard let model else { return }
        followScreenReader(model)
        guard let snap = model.tracker?.snapshot(at: model.now()) else { return }
        let name = snap.pokemon.flatMap { model.data?.species[$0.speciesId]?.speciesName }
        let bench = model.bench.map { "\($0.name) \($0.energy)" }.joined(separator: "  ·  ")
        // Between battles reads come every 2s.
        let stale = model.lastReadAt.map { Date.now.timeIntervalSince($0) > (model.readerIdle ? 4 : 2) } ?? true
        let reader = stale ? "• no screen reads" : model.readerIdle ? "• idle" : "• \(model.readCount) reads"
        guard let buffer = OverlayRenderer.sampleBuffer(
            snap: snap, name: name, bench: bench, battleOver: model.isBattleOver, reader: reader, size: Self.size
        ) else { return }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(buffer)
    }
}

extension OverlayController {
    /// No screen reader, no card: it pops out on leaving the app only while reads are
    /// coming in, and closes when they stop (the broadcast ended). "Pop out overlay" still
    /// opens it by hand.
    fileprivate func followScreenReader(_ model: TrackerModel) {
        let reading = model.lastReadAt.map { Date.now.timeIntervalSince($0) < Self.readingTimeout } ?? false
        guard let pip, reading != wasReading else { return }
        wasReading = reading
        pip.canStartPictureInPictureAutomaticallyFromInline = reading
        if !reading, pip.isPictureInPictureActive { pip.stopPictureInPicture() }
    }
}

extension OverlayController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }
}

/// A live stream with no timeline: nothing to seek, never paused.
extension OverlayController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        completionHandler()
    }
}

/// Draws the overlay card into a video frame.
enum OverlayRenderer {
    static func sampleBuffer(
        snap: OpponentTracker.Snapshot, name: String?, bench: String, battleOver: Bool, reader: String, size: CGSize
    ) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        guard let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Flip to UIKit's top-left origin so string drawing works.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        draw(snap: snap, name: name, bench: bench, battleOver: battleOver, reader: reader, size: size)
        UIGraphicsPopContext()

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        if let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private static func draw(snap: OpponentTracker.Snapshot, name: String?, bench: String, battleOver: Bool, reader: String, size: CGSize) {
        let pad: CGFloat = 24
        UIColor(white: 0.08, alpha: 1).setFill()
        UIRectFill(CGRect(origin: .zero, size: size))

        func text(_ s: String, at p: CGPoint, size: CGFloat, weight: UIFont.Weight = .semibold,
                  color: UIColor = .white, alignRight: Bool = false, width: CGFloat = 0) {
            let style = NSMutableParagraphStyle()
            style.alignment = alignRight ? .right : .left
            style.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
                .foregroundColor: color, .paragraphStyle: style,
            ]
            let w = width > 0 ? width : 400
            (s as NSString).draw(in: CGRect(x: alignRight ? p.x - w : p.x, y: p.y, width: w, height: size * 1.3), withAttributes: attrs)
        }

        // Header: opponent and status.
        let status = battleOver ? "BATTLE OVER" : snap.isPaused ? "PAUSED" : nil
        // "vs " keeps the screen reader, which also sees this card, from taking it for the
        // opponent's name box.
        text(name.map { "vs \($0)" } ?? "Waiting for opponent", at: CGPoint(x: pad, y: pad), size: 34, width: 380)
        if let status {
            text(status, at: CGPoint(x: size.width - pad, y: pad + 4), size: 26, weight: .bold, color: .systemOrange, alignRight: true, width: 200)
        }
        // Whether screen reads are coming in ("•" keeps the screen reader from reading it).
        text(reader, at: CGPoint(x: size.width - pad, y: pad + 38), size: 20, weight: .medium,
             color: reader.contains("no") ? .systemOrange : UIColor(white: 0.45, alpha: 1), alignRight: true, width: 170)
        // Benched Pokémon keep their energy for when they switch back in.
        if !bench.isEmpty {
            text("Bench: \(bench)", at: CGPoint(x: pad, y: size.height - pad - 64), size: 24, weight: .medium,
                 color: UIColor(white: 0.75, alpha: 1), width: size.width - pad * 2)
        }
        guard snap.pokemon != nil else { return }

        // Energy number and bar.
        text("\(snap.energy)", at: CGPoint(x: pad, y: 78), size: 110, weight: .heavy)
        let bar = CGRect(x: pad, y: size.height - pad - 22, width: size.width - pad * 2, height: 22)
        UIColor(white: 0.25, alpha: 1).setFill()
        UIBezierPath(roundedRect: bar, cornerRadius: 11).fill()
        UIColor.systemBlue.setFill()
        var fill = bar
        fill.size.width *= CGFloat(snap.energy) / CGFloat(maxEnergy)
        UIBezierPath(roundedRect: fill, cornerRadius: 11).fill()

        // Up to two charged moves: revealed or recommended first.
        let x = size.width * 0.42
        for (i, status) in snap.chargedMoves.prefix(2).enumerated() {
            let y = 92 + CGFloat(i) * 72
            let star = status.isRecommended && !status.isRevealed ? "★ " : ""
            text("\(star)\(status.move.name) · \(status.move.energy)", at: CGPoint(x: x, y: y), size: 26, weight: .medium,
                 color: UIColor(white: 0.75, alpha: 1), width: size.width - x - pad)
            let readiness: String
            if status.ready { readiness = "READY" }
            else if let turns = status.turnsUntilReady { readiness = "\(status.fastMovesNeeded) fast · \(turns)T" }
            else { readiness = "fast move?" }
            text(readiness, at: CGPoint(x: x, y: y + 30), size: 30, weight: .bold,
                 color: status.ready ? .systemRed : .white, width: size.width - x - pad)
        }
    }
}

/// Hosts the display layer in the app. It has to be on screen for PiP to start.
struct OverlayPreview: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.layer.addSublayer(layer)
        view.layer.cornerRadius = 12
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {}

    final class LayerView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.sublayers?.forEach { $0.frame = bounds }
        }
    }
}
