import Foundation

/// Passes screen reads from the broadcast extension to the app through a shared
/// App Group, with a Darwin notification to say new reads are available. The last
/// few reads are kept so the app can catch up in order if it was briefly busy.
public enum BroadcastChannel {
    public static let appGroup = "group.com.jovenstriker.mango"
    public static let notificationName = "com.jovenstriker.mango.screenText"
    /// Bundle ID of the broadcast upload extension, for the in-app picker.
    public static let extensionBundleID = "com.jovenstriker.mango.broadcast"

    private static let readsKey = "screenReads"
    private static let idleKey = "readerIdleSince"
    private static let keep = 12

    /// Between battles the reader reads this often instead of every 0.25s...
    public static let idleInterval: TimeInterval = 2
    /// ...and stops the broadcast after this long with no new battle.
    public static let idleStopAfter: TimeInterval = 180

    /// Set by the app when a battle ends (`CACurrentMediaTime()`), cleared when the next one
    /// starts, so the reader slows down in between.
    public static var idleSince: TimeInterval? {
        get {
            let t = UserDefaults(suiteName: appGroup)?.double(forKey: idleKey) ?? 0
            return t > 0 ? t : nil
        }
        set {
            if let newValue { UserDefaults(suiteName: appGroup)?.set(newValue, forKey: idleKey) }
            else { UserDefaults(suiteName: appGroup)?.removeObject(forKey: idleKey) }
        }
    }

    public static func send(_ read: ScreenRead) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        var reads = recent(in: defaults)
        reads.append(read)
        if reads.count > keep { reads.removeFirst(reads.count - keep) }
        guard let data = try? JSONEncoder().encode(reads) else { return }
        defaults.set(data, forKey: readsKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil, nil, true
        )
    }

    /// Reads newer than `time`, oldest first.
    public static func reads(after time: TimeInterval) -> [ScreenRead] {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return [] }
        return recent(in: defaults).filter { $0.time > time }
    }

    private static func recent(in defaults: UserDefaults) -> [ScreenRead] {
        guard let data = defaults.data(forKey: readsKey) else { return [] }
        return (try? JSONDecoder().decode([ScreenRead].self, from: data)) ?? []
    }
}
