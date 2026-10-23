import SwiftUI

@main
struct ManGoApp: App {
    @State private var model = TrackerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TrackerView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            // Opening ManGo after a battle moves its recording into Files.
            if phase == .active { model.collectRecordings() }
        }
    }
}
