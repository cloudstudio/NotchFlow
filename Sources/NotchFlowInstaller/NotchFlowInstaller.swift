import Darwin
import Foundation
import NotchFlowCore

@main
struct NotchFlowInstaller {
    static let claudeEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop",
        "Stop", "StopFailure", "SessionEnd"
    ]
    static let codexEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PostToolUse", "SubagentStart", "SubagentStop", "Stop"
    ]

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return
        }
        if arguments.contains("--uninstall") {
            try uninstall()
            return
        }
        try install(repair: arguments.contains("--repair"))
    }

    private static func printUsage() {
        print("""
        notchflow-install [--repair | --uninstall]

          (default)    Install Claude Code and Codex hooks plus launch at login.
                       Existing third-party hooks are preserved; previous
                       NotchFlow entries are replaced in place.
          --repair     Same as install; use after moving or updating the app.
          --uninstall  Remove every NotchFlow hook and the launch agent.
                       Configuration backups are kept.
        """)
    }

    // MARK: - Install

    private static func install(repair: Bool) throws {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let hookBinary = home
            .appendingPathComponent("Applications/NotchFlow.app/Contents/Helpers/notchflow-hook")
            .path
        guard fileManager.isExecutableFile(atPath: hookBinary) else {
            throw InstallError("Missing packaged helper at \(hookBinary)")
        }

        let backupRoot = try makeBackupDirectory()

        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        if fileManager.fileExists(atPath: claudeSettings.path) {
            try backup(claudeSettings, as: "claude-settings.json", into: backupRoot)
        }
        try installClaudeHooks(at: claudeSettings, hookBinary: hookBinary)
        print(repair ? "Repaired Claude Code hooks" : "Installed Claude Code hooks")

        let codexHooks = home.appendingPathComponent(".codex/hooks.json")
        if fileManager.fileExists(atPath: codexHooks.path) {
            try backup(codexHooks, as: "codex-hooks.json", into: backupRoot)
        }
        try installCodexHooks(at: codexHooks, hookBinary: hookBinary)
        print("Installed Codex hooks (review once with /hooks)")

        let launchAgent = launchAgentURL()
        if fileManager.fileExists(atPath: launchAgent.path) {
            try backup(launchAgent, as: "app.notchflow.NotchFlow.plist", into: backupRoot)
        }
        try installLaunchAgent(at: launchAgent, appPath: home
            .appendingPathComponent("Applications/NotchFlow.app").path)
        print("Installed launch-at-login agent")
        print("Backup: \(backupRoot.path)")
    }

    // MARK: - Uninstall

    private static func uninstall() throws {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let backupRoot = try makeBackupDirectory()

        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        if fileManager.fileExists(atPath: claudeSettings.path) {
            try backup(claudeSettings, as: "claude-settings.json", into: backupRoot)
            var root = try readJSONObject(claudeSettings)
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in Set(claudeEvents).union(hooks.keys) {
                guard let groups = hooks[event] as? [[String: Any]] else { continue }
                let cleaned = HookConfigurationMerger.removingOwnedHandlers(
                    from: groups,
                    commandMarker: "notchflow-hook"
                )
                hooks[event] = cleaned.isEmpty ? nil : cleaned
            }
            root["hooks"] = hooks.isEmpty ? nil : hooks
            try writeJSONObject(root, to: claudeSettings)
            print("Removed Claude Code hooks")
        }

        let codexHooks = home.appendingPathComponent(".codex/hooks.json")
        if fileManager.fileExists(atPath: codexHooks.path) {
            try backup(codexHooks, as: "codex-hooks.json", into: backupRoot)
            var root = try readJSONObject(codexHooks)
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in Set(codexEvents).union(hooks.keys) {
                guard let groups = hooks[event] as? [[String: Any]] else { continue }
                let cleaned = HookConfigurationMerger.removingOwnedHandlers(
                    from: groups,
                    commandMarker: "notchflow-hook"
                )
                hooks[event] = cleaned.isEmpty ? nil : cleaned
            }
            if hooks.isEmpty {
                try fileManager.removeItem(at: codexHooks)
            } else {
                root["hooks"] = hooks
                try writeJSONObject(root, to: codexHooks)
            }
            print("Removed Codex hooks")
        }

        let launchAgent = launchAgentURL()
        if fileManager.fileExists(atPath: launchAgent.path) {
            try fileManager.removeItem(at: launchAgent)
            print("Removed launch-at-login agent")
        }

        print("Backup: \(backupRoot.path)")
        print("Delete ~/Applications/NotchFlow.app and ~/Library/Application Support/NotchFlow to finish.")
    }

    // MARK: - Pieces

    private static func makeBackupDirectory() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchFlow/backups")
            .appendingPathComponent(formatter.string(from: Date()))
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        return backupRoot
    }

    private static func launchAgentURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/app.notchflow.NotchFlow.plist")
    }

    private static func installClaudeHooks(at url: URL, hookBinary: String) throws {
        var root = try existingJSONObject(at: url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let handler: [String: Any] = [
            "type": "command",
            "command": hookBinary,
            "args": ["--agent", "claude", "--response-timeout", "300"],
            "timeout": 310,
            "statusMessage": "Waiting for NotchFlow"
        ]
        for event in claudeEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = HookConfigurationMerger.removingOwnedHandlers(
                from: groups,
                commandMarker: "notchflow-hook"
            )
            groups.append(["hooks": [handler]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeJSONObject(root, to: url)
    }

    private static func installCodexHooks(at url: URL, hookBinary: String) throws {
        var root = try existingJSONObject(at: url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let escaped = hookBinary.replacingOccurrences(of: "'", with: "'\\''")
        let handler: [String: Any] = [
            "type": "command",
            "command": "'\(escaped)' --agent codex --response-timeout 300",
            "timeout": 310,
            "statusMessage": "Waiting for NotchFlow"
        ]
        for event in codexEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = HookConfigurationMerger.removingOwnedHandlers(
                from: groups,
                commandMarker: "notchflow-hook"
            )
            groups.append(["hooks": [handler]])
            hooks[event] = groups
        }
        root["description"] = "NotchFlow lifecycle integration."
        root["hooks"] = hooks
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeJSONObject(root, to: url)
    }

    private static func installLaunchAgent(at url: URL, appPath: String) throws {
        let plist: [String: Any] = [
            "Label": "app.notchflow.NotchFlow",
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        chmod(url.path, S_IRUSR | S_IWUSR)
    }

    /// A missing file is an empty config; an unreadable one must abort. The
    /// old behavior treated malformed JSON as empty and silently rewrote the
    /// user's settings away.
    private static func existingJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            return try readJSONObject(url)
        } catch {
            throw InstallError(
                "Refusing to touch \(url.path): it exists but is not valid JSON. Fix it (or remove it) and re-run."
            )
        }
    }

    private static func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError("Expected a JSON object at \(url.path)")
        }
        return object
    }

    private static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        chmod(url.path, S_IRUSR | S_IWUSR)
    }

    private static func backup(_ source: URL, as name: String, into directory: URL) throws {
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
    }
}

struct InstallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
