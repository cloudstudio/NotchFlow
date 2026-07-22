import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case cursor
    case gemini
    case openCode = "opencode"
    case unknown

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini"
        case .openCode: return "OpenCode"
        case .unknown: return "Agent"
        }
    }
}

public enum AgentEventType: String, Codable, Sendable {
    case sessionStarted
    case promptSubmitted
    case toolStarted
    case toolFinished
    case permissionRequested
    case turnCompleted
    case sessionStopped
    case sessionFailed
    case subagentStarted
    case subagentStopped
    case quotaUpdated

    public static func fromHookName(_ name: String) -> AgentEventType? {
        switch name.lowercased() {
        case "sessionstart", "session_started", "sessionstarted": return .sessionStarted
        case "userpromptsubmit", "prompt_submitted", "promptsubmitted": return .promptSubmitted
        case "pretooluse", "tool_started", "toolstarted": return .toolStarted
        // A failed tool is a failed TOOL, not a failed session; the session
        // keeps going and the failure feeds stuck detection instead.
        case "posttooluse", "posttoolusefailure", "tool_finished", "toolfinished": return .toolFinished
        case "permissionrequest", "permission_requested", "permissionrequested": return .permissionRequested
        case "stopfailure", "session_failed", "sessionfailed": return .sessionFailed
        case "subagentstart", "subagent_started", "subagentstarted": return .subagentStarted
        case "subagentstop", "subagent_stopped", "subagentstopped": return .subagentStopped
        case "stop", "turn_completed", "turncompleted", "agent-turn-complete": return .turnCompleted
        case "sessionend", "sessionstop", "session_stopped", "sessionstopped": return .sessionStopped
        case "quota", "quota_updated", "quotaupdated": return .quotaUpdated
        default: return nil
        }
    }
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var type: AgentEventType
    public var agent: AgentKind
    public var sessionId: String
    public var parentSessionId: String?
    public var cwd: String?
    public var tool: String?
    public var detail: String?
    public var terminal: String?
    public var tty: String?
    public var agentPid: Int32?
    public var model: String?
    public var transcriptPath: String?
    public var toolFailed: Bool?
    public var quotaUsed: Double?
    public var equivalentCostUSD: Double?
    public var timestamp: Date

    public init(
        schemaVersion: Int = 1,
        type: AgentEventType,
        agent: AgentKind,
        sessionId: String,
        parentSessionId: String? = nil,
        cwd: String? = nil,
        tool: String? = nil,
        detail: String? = nil,
        terminal: String? = nil,
        tty: String? = nil,
        agentPid: Int32? = nil,
        model: String? = nil,
        transcriptPath: String? = nil,
        toolFailed: Bool? = nil,
        quotaUsed: Double? = nil,
        equivalentCostUSD: Double? = nil,
        timestamp: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.type = type
        self.agent = agent
        self.sessionId = sessionId
        self.parentSessionId = parentSessionId
        self.cwd = cwd
        self.tool = tool
        self.detail = detail
        self.terminal = terminal
        self.tty = tty
        self.agentPid = agentPid
        self.model = model
        self.transcriptPath = transcriptPath
        self.toolFailed = toolFailed
        self.quotaUsed = quotaUsed
        self.equivalentCostUSD = equivalentCostUSD
        self.timestamp = timestamp
    }
}

public struct PiperConfiguration: Equatable, Sendable {
    public let binaryPath: String
    public let voicePath: String

    public init(binaryPath: String, voicePath: String) {
        self.binaryPath = binaryPath
        self.voicePath = voicePath
    }
}

/// Finds a local Piper install: explicit paths first, then well-known
/// binaries plus the first voice (.onnx with its adjacent .json) dropped in
/// Application Support/NotchFlow/voices.
public enum PiperLocator {
    public static func locate(
        binaryOverride: String? = UserDefaults.standard.string(forKey: "voice.piperBinaryPath"),
        voiceOverride: String? = UserDefaults.standard.string(forKey: "voice.piperVoicePath"),
        voicesDirectory: URL? = nil
    ) -> PiperConfiguration? {
        let fileManager = FileManager.default
        let binary = ([binaryOverride, "/opt/homebrew/bin/piper", "/usr/local/bin/piper"]
            .compactMap { $0 })
            .first { fileManager.isExecutableFile(atPath: $0) }
        guard let binary else { return nil }

        if let voiceOverride, fileManager.fileExists(atPath: voiceOverride) {
            return PiperConfiguration(binaryPath: binary, voicePath: voiceOverride)
        }
        let directory = voicesDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NotchFlow/voices", isDirectory: true)
        let voices = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        let voice = voices
            .filter { $0.pathExtension == "onnx" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first { fileManager.fileExists(atPath: $0.path + ".json") }
        guard let voice else { return nil }
        return PiperConfiguration(binaryPath: binary, voicePath: voice.resolvingSymlinksInPath().path)
    }
}

public enum BridgeLocation {
    public static var socketPath: String {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base
            .appendingPathComponent("NotchFlow", isDirectory: true)
            .appendingPathComponent("bridge.sock")
            .path
    }

    public static var pricingOverridePath: String {
        supportFile("pricing.json")
    }

    public static var openAIPricingOverridePath: String {
        supportFile("openai-pricing.json")
    }

    private static func supportFile(_ name: String) -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NotchFlow", isDirectory: true)
            .appendingPathComponent(name)
            .path
    }
}

public enum TerminalCatalog {
    /// Bundle identifiers a TERM_PROGRAM value can map to, used for
    /// foreground suppression in the hook and click-to-jump in the app.
    public static func bundleIdentifiers(forProgram program: String) -> [String] {
        switch program {
        case "iTerm.app": return ["com.googlecode.iterm2"]
        case "Apple_Terminal": return ["com.apple.Terminal"]
        case "ghostty": return ["com.mitchellh.ghostty"]
        case "WezTerm": return ["com.github.wez.wezterm"]
        case "WarpTerminal": return ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview", "dev.warp.Warp-Beta"]
        case "Codex Desktop": return ["com.openai.codex", "com.openai.chat"]
        case "Hyper": return ["co.zeit.hyper"]
        case "vscode":
            return [
                "com.microsoft.VSCode",
                "com.microsoft.VSCodeInsiders",
                "com.todesktop.230313mzl4w4u92",
                "com.vscodium"
            ]
        default: return []
        }
    }

    public static func program(fromTerminalIdentity identity: String?) -> String? {
        identity?.components(separatedBy: " · ").first
    }
}
