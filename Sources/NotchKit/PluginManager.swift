import SwiftUI

/// Local, no-account plugins — small monitoring automations toggled on/off and
/// persisted. They act on observed agent sessions, so they belong to the notch
/// (the monitor), and the product's Settings UI just reads them.
@MainActor
public final class PluginManager: ObservableObject {
    public static let shared = PluginManager()

    public struct Plugin: Identifiable {
        public let id: String
        public let name: String
        public let detail: String
        public let symbol: String
    }

    public let plugins: [Plugin] = [
        .init(id: "autoapprove", name: "Auto-approve reads (Auto-pilot)",
              detail: "Silently allow read-only tools (Read, Grep, LS, Glob, WebFetch…). Never writes, edits, or shell — those still ask.",
              symbol: "checkmark.shield.fill"),
        .init(id: "notifyfocus", name: "Click-to-focus alerts",
              detail: "Desktop notification when an agent needs you, fails, or gets stuck — click it to jump straight to that terminal.",
              symbol: "bell.badge.fill"),
        .init(id: "watchdog", name: "Idle / stuck watchdog",
              detail: "Alerts when an agent has waited on a permission too long, or is repeating a failing command.",
              symbol: "eye.trianglebadge.exclamationmark.fill"),
    ]

    @Published public var enabled: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabled), forKey: "plugins.enabled") }
    }

    private init() {
        enabled = Set(UserDefaults.standard.stringArray(forKey: "plugins.enabled") ?? ["notifyfocus", "watchdog"])
    }

    /// Read-only tools safe to auto-approve. Never writes/edits/shell.
    public static let safeTools: Set<String> = [
        "read", "grep", "glob", "ls", "webfetch", "websearch", "notebookread",
        "read_file", "list_dir", "search",
    ]

    public func isOn(_ id: String) -> Bool { enabled.contains(id) }

    public func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { self.enabled.contains(id) },
                set: { if $0 { self.enabled.insert(id) } else { self.enabled.remove(id) } })
    }
}
