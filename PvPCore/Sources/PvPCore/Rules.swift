import Foundation

/// Testing: turn individual counting rules off, to see which ones earn their keep
/// (battle-report's RULES_OFF, or MANGO_RULES_OFF for the tests). Empty in the app.
public enum Rules {
    nonisolated(unsafe) public static var disabled: Set<String> =
        Set((ProcessInfo.processInfo.environment["MANGO_RULES_OFF"] ?? "").split(separator: ",").map(String.init))
    static func off(_ name: String) -> Bool { disabled.contains(name) }
}
