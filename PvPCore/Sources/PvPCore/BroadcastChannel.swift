import Foundation

/// Passes screen reads from the broadcast extension to the app through a shared
/// App Group, with a Darwin notification to say a new read is available.
public enum BroadcastChannel {
    public static let appGroup = "group.com.jovenstriker.mango"
    public static let notificationName = "com.jovenstriker.mango.screenText"
    /// Bundle ID of the broadcast upload extension, for the in-app picker.
    public static let extensionBundleID = "com.jovenstriker.mango.broadcast"

    private static let linesKey = "screenTextLines"

    public static func send(_ lines: [RecognizedText]) {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = try? JSONEncoder().encode(lines)
        else { return }
        defaults.set(data, forKey: linesKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil, nil, true
        )
    }

    public static func latest() -> [RecognizedText] {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: linesKey) else { return [] }
        return (try? JSONDecoder().decode([RecognizedText].self, from: data)) ?? []
    }
}
