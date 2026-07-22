import XCTest
@testable import NotchKit

/// Plugin state gates safety-relevant behavior (auto-approve, watchdog, voice).
/// A bad default — shipping auto-approve ON — or broken persistence would change
/// that behavior silently.
@MainActor
final class PluginManagerTests: XCTestCase {
    private func scratch() -> UserDefaults {
        UserDefaults(suiteName: "notchflow.tests.\(UUID().uuidString)")!
    }

    func testDefaultsAreNotifyAndWatchdogOnly() {
        let pm = PluginManager(defaults: scratch())
        XCTAssertEqual(pm.enabled, ["notifyfocus", "watchdog"])
        // Auto-approve must never be on by default — it is the one plugin that
        // can act without a human.
        XCTAssertFalse(pm.isOn("autoapprove"))
        XCTAssertFalse(pm.isOn("voice"))
    }

    func testTogglePersistsToStore() {
        let store = scratch()
        let pm = PluginManager(defaults: store)
        pm.binding("voice").wrappedValue = true
        XCTAssertTrue(pm.isOn("voice"))
        XCTAssertEqual(Set(store.stringArray(forKey: "plugins.enabled") ?? []), pm.enabled)

        pm.binding("voice").wrappedValue = false
        XCTAssertFalse(pm.isOn("voice"))
        XCTAssertFalse(Set(store.stringArray(forKey: "plugins.enabled") ?? []).contains("voice"))
    }

    func testPreseededArrayLoadsOnInit() {
        let store = scratch()
        store.set(["autoapprove"], forKey: "plugins.enabled")
        let pm = PluginManager(defaults: store)
        XCTAssertEqual(pm.enabled, ["autoapprove"])
    }

    func testSafeToolsContract() {
        for tool in ["read", "grep", "glob", "ls", "webfetch", "websearch"] {
            XCTAssertTrue(PluginManager.safeTools.contains(tool), "\(tool) should be read-only-safe")
        }
        for tool in ["write", "edit", "bash", "shell"] {
            XCTAssertFalse(PluginManager.safeTools.contains(tool), "\(tool) must not be safelisted")
        }
    }
}
