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
///
/// The system picker draws its own icon off-center in a toolbar item, so it sits hidden
/// behind a normal toolbar button that taps it.
struct BroadcastPickerButton: View {
    @State private var picker = BroadcastPicker()

    var body: some View {
        Button("Screen reader", systemImage: "record.circle") { picker.show() }
            .background(BroadcastPicker.Host(view: picker.view).frame(width: 1, height: 1).opacity(0.01))
    }
}

@MainActor
final class BroadcastPicker {
    let view: RPSystemBroadcastPickerView = {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.preferredExtension = BroadcastChannel.extensionBundleID
        picker.showsMicrophoneButton = false
        return picker
    }()

    /// Opens the start/stop broadcast sheet, as if its own button were tapped.
    func show() {
        for case let button as UIButton in view.subviews {
            button.sendActions(for: .touchUpInside)
        }
    }

    /// Keeps the picker in the view hierarchy, which it needs to present the sheet.
    struct Host: UIViewRepresentable {
        let view: RPSystemBroadcastPickerView
        func makeUIView(context: Context) -> RPSystemBroadcastPickerView { view }
        func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
    }
}
