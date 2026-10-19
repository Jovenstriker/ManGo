import PvPCore
import ReplayKit
import SwiftUI

/// Calls `handler` whenever the broadcast extension posts a new screen read.
enum ScreenTextObserver {
    private static var handler: (() -> Void)?

    static func start(_ handler: @escaping () -> Void) {
        let first = self.handler == nil
        self.handler = handler
        guard first else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                Task { @MainActor in ScreenTextObserver.handler?() }
            },
            BroadcastChannel.notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }
}

/// The system "start broadcast" button, preset to ManGo's screen reader.
struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = BroadcastChannel.extensionBundleID
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
