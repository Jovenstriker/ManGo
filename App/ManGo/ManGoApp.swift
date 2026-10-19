import SwiftUI

@main
struct ManGoApp: App {
    @State private var model = TrackerModel()

    var body: some Scene {
        WindowGroup {
            TrackerView(model: model)
        }
    }
}
