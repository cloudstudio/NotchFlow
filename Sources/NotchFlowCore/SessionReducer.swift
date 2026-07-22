import Foundation

public enum SessionStatus: String, Codable, Equatable, Sendable {
    case working
    case runningTool
    case waitingPermission
    case idle
    case completed
    case failed
}

/// One line of a session's recent activity, kept so a glance at the island
/// answers "what has it been doing" without opening the terminal.
public struct ActivityEntry: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let tool: String?
    public let detail: String?
    public var failed: Bool?

    public init(timestamp: Date, tool: String?, detail: String?, failed: Bool? = nil) {
        self.timestamp = timestamp
        self.tool = tool
        self.detail = detail
        self.failed = failed
    }
}

public struct AgentSession: Identifiable, Codable, Equatable, Sendable {
    public static let historyLimit = 8

    public let id: String
    public var parentId: String?
    public var agent: AgentKind
    public var cwd: String?
    public var terminal: String?
    public var tty: String?
    public var agentPid: Int32?
    public var model: String?
    public var transcriptPath: String?
    public var status: SessionStatus
    public var tool: String?
    public var detail: String?
    public var prompt: String?
    /// Non-nil while the session looks wedged: repeating the same command
    /// or chaining failures. The status stays live; this is judgment on top.
    public var stuckReason: String?
    /// True when the cost below is a floor: some messages used a model the
    /// pricing table does not know, so their share is missing.
    public var costIncomplete: Bool?
    /// Files edited during the current assignment; resets with each prompt
    /// so the outcome card reads "what did THIS ask touch".
    public var filesTouched: [String]
    /// When the current assignment was given; startedAt covers the whole
    /// session, this covers the encargo.
    public var promptedAt: Date?
    public var history: [ActivityEntry]
    public var equivalentCostUSD: Double?
    public var startedAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        parentId: String? = nil,
        agent: AgentKind,
        cwd: String? = nil,
        terminal: String? = nil,
        tty: String? = nil,
        agentPid: Int32? = nil,
        model: String? = nil,
        transcriptPath: String? = nil,
        status: SessionStatus = .working,
        tool: String? = nil,
        detail: String? = nil,
        prompt: String? = nil,
        stuckReason: String? = nil,
        costIncomplete: Bool? = nil,
        filesTouched: [String] = [],
        promptedAt: Date? = nil,
        history: [ActivityEntry] = [],
        equivalentCostUSD: Double? = nil,
        startedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.parentId = parentId
        self.agent = agent
        self.cwd = cwd
        self.terminal = terminal
        self.tty = tty
        self.agentPid = agentPid
        self.model = model
        self.transcriptPath = transcriptPath
        self.status = status
        self.tool = tool
        self.detail = detail
        self.prompt = prompt
        self.stuckReason = stuckReason
        self.costIncomplete = costIncomplete
        self.filesTouched = filesTouched
        self.promptedAt = promptedAt
        self.history = history
        self.equivalentCostUSD = equivalentCostUSD
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    mutating func recordActivity(_ entry: ActivityEntry) {
        history.append(entry)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        agent = try container.decode(AgentKind.self, forKey: .agent)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        terminal = try container.decodeIfPresent(String.self, forKey: .terminal)
        tty = try container.decodeIfPresent(String.self, forKey: .tty)
        agentPid = try container.decodeIfPresent(Int32.self, forKey: .agentPid)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        status = try container.decode(SessionStatus.self, forKey: .status)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        stuckReason = try container.decodeIfPresent(String.self, forKey: .stuckReason)
        costIncomplete = try container.decodeIfPresent(Bool.self, forKey: .costIncomplete)
        filesTouched = try container.decodeIfPresent([String].self, forKey: .filesTouched) ?? []
        promptedAt = try container.decodeIfPresent(Date.self, forKey: .promptedAt)
        history = try container.decodeIfPresent([ActivityEntry].self, forKey: .history) ?? []
        equivalentCostUSD = try container.decodeIfPresent(Double.self, forKey: .equivalentCostUSD)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? updatedAt
    }
}

public struct QuotaWindow: Codable, Equatable, Sendable {
    public var usedFraction: Double
    public var durationMinutes: Int?
    public var resetsAt: Date?

    public init(usedFraction: Double, durationMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.usedFraction = min(max(usedFraction, 0), 1)
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }
}

public struct QuotaState: Codable, Equatable, Sendable {
    public var provider: AgentKind
    public var primary: QuotaWindow?
    public var secondary: QuotaWindow?
    public var planName: String?
    /// True when the stored credential no longer works (expired OAuth).
    /// The UI must say so instead of silently showing nothing: a vanished
    /// quota reads as "plenty left", which is a lie.
    public var authProblem: Bool?
    public var updatedAt: Date

    public init(
        provider: AgentKind = .unknown,
        primary: QuotaWindow? = nil,
        secondary: QuotaWindow? = nil,
        planName: String? = nil,
        authProblem: Bool? = nil,
        updatedAt: Date = Date()
    ) {
        self.provider = provider
        self.primary = primary
        self.secondary = secondary
        self.planName = planName
        self.authProblem = authProblem
        self.updatedAt = updatedAt
    }

    public init(provider: AgentKind, usedFraction: Double, updatedAt: Date = Date()) {
        self.init(
            provider: provider,
            primary: QuotaWindow(usedFraction: usedFraction),
            updatedAt: updatedAt
        )
    }

    public var usedFraction: Double {
        max(primary?.usedFraction ?? 0, secondary?.usedFraction ?? 0)
    }

    public func isStale(now: Date = Date(), after seconds: TimeInterval = 600) -> Bool {
        now.timeIntervalSince(updatedAt) > seconds
    }
}

public struct QuotaTone: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public static func forUsage(_ rawUsage: Double) -> QuotaTone {
        let usage = min(max(rawUsage, 0), 1)
        let heat = pow(usage, 1.55)
        return QuotaTone(
            red: 0.05 + (0.95 * heat),
            green: 0.04 * (1 - heat),
            blue: 0.04 * (1 - heat)
        )
    }
}

public struct SessionReducer: Sendable {
    public private(set) var sessions: [String: AgentSession] = [:]
    public private(set) var quotas: [AgentKind: QuotaState] = [:]
    /// Task descriptions seen on a parent's Task tool calls, waiting for
    /// their subagent to start: the child's own hook only knows its type,
    /// the parent's tool input knows the human-readable task name.
    private var pendingSubagentNames: [String: [String]] = [:]

    public init(
        sessions: [String: AgentSession] = [:],
        quotas: [AgentKind: QuotaState] = [:]
    ) {
        self.sessions = sessions
        self.quotas = quotas
    }

    public var orderedSessions: [AgentSession] {
        sessions.values.sorted { lhs, rhs in
            if lhs.status.sortPriority != rhs.status.sortPriority {
                return lhs.status.sortPriority < rhs.status.sortPriority
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// The freshest, most constrained window across providers; drives the border heat.
    public func hottestQuota(now: Date = Date()) -> QuotaState? {
        quotas.values
            .filter { !$0.isStale(now: now) && $0.authProblem != true }
            .max { $0.usedFraction < $1.usedFraction }
    }

    public var orderedQuotas: [QuotaState] {
        quotas.values.sorted { $0.provider.rawValue < $1.provider.rawValue }
    }

    public mutating func apply(_ event: AgentEvent) {
        if event.type == .quotaUpdated {
            guard let used = event.quotaUsed else { return }
            applyQuota(QuotaState(provider: event.agent, usedFraction: used, updatedAt: event.timestamp))
            return
        }

        if let existing = sessions[event.sessionId], event.timestamp < existing.updatedAt {
            return
        }

        var session = sessions[event.sessionId] ?? AgentSession(
            id: event.sessionId,
            parentId: event.parentSessionId,
            agent: event.agent,
            cwd: event.cwd,
            terminal: event.terminal,
            tty: event.tty,
            startedAt: event.timestamp,
            updatedAt: event.timestamp
        )

        session.parentId = event.parentSessionId ?? session.parentId
        session.agent = event.agent == .unknown ? session.agent : event.agent
        session.cwd = event.cwd ?? session.cwd
        session.terminal = event.terminal ?? session.terminal
        session.tty = event.tty ?? session.tty
        session.agentPid = event.agentPid ?? session.agentPid
        session.model = event.model ?? session.model
        session.transcriptPath = event.transcriptPath ?? session.transcriptPath
        session.equivalentCostUSD = event.equivalentCostUSD ?? session.equivalentCostUSD
        session.updatedAt = event.timestamp

        switch event.type {
        case .subagentStarted:
            session.status = .working
            session.tool = nil
            // The subagent's name survives in prompt, where later tool
            // events cannot clobber it. Prefer the parent's queued task
            // description (type + human name) over the bare agent type.
            if let parentId = session.parentId,
               var queue = pendingSubagentNames[parentId], !queue.isEmpty {
                session.prompt = queue.removeFirst()
                pendingSubagentNames[parentId] = queue
            } else {
                session.prompt = event.detail ?? session.prompt
            }
        case .sessionStarted:
            session.status = .working
            session.tool = nil
            session.detail = event.detail ?? session.detail
        case .promptSubmitted:
            session.status = .working
            session.tool = nil
            session.prompt = event.detail ?? session.prompt
            session.detail = nil
            session.stuckReason = nil
            session.filesTouched.removeAll()
            session.promptedAt = event.timestamp
            session.history.removeAll()
        case .toolStarted:
            session.status = .runningTool
            session.tool = event.tool
            session.detail = event.detail
            session.recordActivity(ActivityEntry(
                timestamp: event.timestamp,
                tool: event.tool,
                detail: event.detail
            ))
            if event.tool == "Task" || event.tool == "Agent", let name = event.detail {
                var queue = pendingSubagentNames[event.sessionId, default: []]
                queue.append(name)
                pendingSubagentNames[event.sessionId] = Array(queue.suffix(32))
            }
            if let tool = event.tool, Self.editTools.contains(tool),
               let path = event.detail,
               !session.filesTouched.contains(path),
               session.filesTouched.count < 64 {
                session.filesTouched.append(path)
            }
            session.stuckReason = Self.stuckReason(for: session.history)
        case .toolFinished:
            session.status = .working
            session.tool = nil
            session.detail = event.detail
            if let failed = event.toolFailed, var last = session.history.last {
                last.failed = failed
                session.history[session.history.count - 1] = last
            }
            session.stuckReason = Self.stuckReason(for: session.history)
        case .permissionRequested:
            session.status = .waitingPermission
            session.tool = event.tool
            session.detail = event.detail
        case .turnCompleted:
            session.status = .idle
            session.tool = nil
            session.detail = event.detail ?? session.detail
            session.stuckReason = nil
        case .sessionStopped, .subagentStopped:
            session.status = .completed
            session.tool = nil
            session.detail = event.detail ?? session.detail
            if event.type == .sessionStopped {
                pendingSubagentNames.removeValue(forKey: event.sessionId)
            }
        case .sessionFailed:
            session.status = .failed
            session.tool = event.tool
            session.detail = event.detail
        case .quotaUpdated:
            break
        }

        sessions[event.sessionId] = session
    }

    public mutating func applyQuota(_ newQuota: QuotaState) {
        if let existing = quotas[newQuota.provider],
           newQuota.updatedAt < existing.updatedAt { return }
        quotas[newQuota.provider] = newQuota
    }

    public mutating func removeQuota(provider: AgentKind) {
        quotas.removeValue(forKey: provider)
    }

    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// Judgment over the recent activity: the same command spinning three
    /// or more times, or failures chaining, reads as wedged even while the
    /// status says working.
    static func stuckReason(for history: [ActivityEntry]) -> String? {
        let recent = history.suffix(4)
        if recent.count >= 3 {
            let signatures = recent.suffix(3).map { "\($0.tool ?? "")|\($0.detail ?? "")" }
            if Set(signatures).count == 1, let entry = recent.last, let tool = entry.tool {
                let target = entry.detail.map { " \($0.prefix(30))" } ?? ""
                return "3x \(tool)\(target)"
            }
        }
        let trailingFailures = history.reversed().prefix { $0.failed == true }.count
        if trailingFailures >= 2 {
            let tool = history.last?.tool ?? "tool"
            return "\(trailingFailures) failures in a row (\(tool))"
        }
        return nil
    }

    /// The Stop hook races the CLI's final transcript flush, so the closing
    /// message it reads is one behind. A delayed re-read lands here; it only
    /// applies while the session still waits, never over a new turn.
    public mutating func applySummary(
        sessionId: String,
        detail: String?,
        model: String?,
        costUSD: Double?,
        costIncomplete: Bool? = nil
    ) {
        guard var session = sessions[sessionId],
              session.status == .idle || session.status == .completed else { return }
        if let detail { session.detail = detail }
        if let model { session.model = model }
        if let costUSD { session.equivalentCostUSD = costUSD }
        if let costIncomplete { session.costIncomplete = costIncomplete }
        sessions[sessionId] = session
    }

    /// Mid-turn cost refresh: only the money fields move, never the
    /// status, detail or freshness of the session.
    public mutating func applyLiveCost(
        sessionId: String,
        costUSD: Double,
        costIncomplete: Bool? = nil
    ) {
        guard var session = sessions[sessionId] else { return }
        session.equivalentCostUSD = costUSD
        if let costIncomplete { session.costIncomplete = costIncomplete }
        sessions[sessionId] = session
    }

    /// Once the user answers from the notch, the provider proceeds without
    /// emitting a fresh event, so the attention state must clear here.
    public mutating func clearAttention(sessionId: String, at date: Date = Date()) {
        guard var session = sessions[sessionId],
              session.status == .waitingPermission else { return }
        session.status = .working
        session.tool = nil
        session.updatedAt = date
        sessions[sessionId] = session
    }

    /// Idle sessions the user never came back to become completed; old
    /// completed sessions leave the list entirely. `keeping` protects
    /// finished sessions whose outcome the user has not reviewed yet.
    ///
    /// A session with a PID is kept honest by the process liveness check; a
    /// PID-less one (transcript/rollout tailing) has no process to poll, so
    /// if it never receives its closing event it would zombie in `working`
    /// forever. `staleWorkingAfter` is that backstop: long silence with no
    /// process means the turn is over. A later event still revives it.
    public mutating func expireSessions(
        now: Date = Date(),
        idleAfter: TimeInterval = 1_800,
        removeAfter: TimeInterval = 7_200,
        staleWorkingAfter: TimeInterval = 900,
        keeping: Set<String> = []
    ) {
        let activeStatuses: Set<SessionStatus> = [.working, .runningTool, .waitingPermission]
        for (key, session) in sessions {
            if session.status == .idle, now.timeIntervalSince(session.updatedAt) > idleAfter {
                sessions[key]?.status = .completed
                sessions[key]?.updatedAt = now
            } else if activeStatuses.contains(session.status),
                      session.agentPid == nil,
                      now.timeIntervalSince(session.updatedAt) > staleWorkingAfter {
                sessions[key]?.status = .completed
            } else if session.status == .completed || session.status == .failed,
                      !keeping.contains(key),
                      now.timeIntervalSince(session.updatedAt) > removeAfter {
                sessions.removeValue(forKey: key)
            }
        }
    }
}

private extension SessionStatus {
    var sortPriority: Int {
        switch self {
        case .waitingPermission: return 0
        case .runningTool: return 1
        case .working: return 2
        case .failed: return 3
        case .idle: return 4
        case .completed: return 5
        }
    }
}
