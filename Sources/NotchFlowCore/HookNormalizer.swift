import Foundation

public struct HookContext {
    public var forcedAgent: AgentKind?
    public var environment: [String: String]
    public var tty: String?
    public var agentPid: Int32?
    /// When true, interactive requests (permissions, questions, plans) are
    /// reported as telemetry only, so the provider's own UI handles them.
    public var suppressInteractions: Bool

    public init(
        forcedAgent: AgentKind? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tty: String? = nil,
        agentPid: Int32? = nil,
        suppressInteractions: Bool = false
    ) {
        self.forcedAgent = forcedAgent
        self.environment = environment
        self.tty = tty
        self.agentPid = agentPid
        self.suppressInteractions = suppressInteractions
    }
}

public struct NormalizedHook {
    public let envelope: BridgeEnvelope
    public let toolInput: [String: Any]

    public init(envelope: BridgeEnvelope, toolInput: [String: Any]) {
        self.envelope = envelope
        self.toolInput = toolInput
    }
}

public enum HookNormalizer {
    public static func normalize(
        input: Data,
        context: HookContext,
        pricing: ClaudePricing = .load()
    ) -> NormalizedHook? {
        guard let object = try? JSONSerialization.jsonObject(with: input),
              let payload = object as? [String: Any] else { return nil }

        let eventName = string(payload["hook_event_name"])
            ?? string(payload["event"])
            ?? string(payload["type"])
            ?? ""
        guard let type = AgentEventType.fromHookName(eventName) else { return nil }
        let providerSessionId = string(payload["session_id"])
            ?? string(payload["sessionId"])
            ?? string(payload["thread-id"])
            ?? string(payload["thread_id"])
            ?? UUID().uuidString
        // Any event carrying an agent id happened inside that subagent, so
        // it belongs to the child session; tool activity then shows under
        // the child instead of polluting the parent.
        let agentId = string(payload["agent_id"]) ?? string(payload["agentId"])
        let sessionId = agentId ?? providerSessionId
        let parentSessionId = agentId != nil
            ? providerSessionId
            : (string(payload["parent_session_id"]) ?? string(payload["parentSessionId"]))
        let agent = context.forcedAgent
            ?? AgentKind(rawValue: string(payload["agent"])?.lowercased() ?? "")
            ?? inferAgent(environment: context.environment)
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let tool = string(payload["tool_name"]) ?? string(payload["tool"])
        let questions = parseQuestions(toolInput["questions"])
        let subagentName: String? = {
            let type = string(payload["agent_type"]) ?? string(toolInput["subagent_type"])
            let description = string(payload["description"]) ?? string(toolInput["description"])
            switch (type, description) {
            case let (type?, description?): return "\(type) (\(description))"
            case let (type?, nil): return type
            case let (nil, description?): return description
            default: return nil
            }
        }()
        let detail = string(toolInput["command"])
            ?? string(toolInput["file_path"])
            ?? string(toolInput["path"])
            ?? questions.first?.question
            ?? string(toolInput["plan"])
            ?? subagentName
            ?? string(payload["prompt"])
            ?? string(payload["detail"])
        let transcriptPath = type == .subagentStopped
            ? (string(payload["agent_transcript_path"]) ?? string(payload["transcript_path"]))
            : string(payload["transcript_path"])
        let costEvents: Set<AgentEventType> = [.turnCompleted, .sessionStopped, .subagentStopped]
        let transcriptSummary = costEvents.contains(type) && agent == .claude
            ? TranscriptCost.claudeTranscriptSummary(transcriptPath: transcriptPath, pricing: pricing)
            : nil
        let equivalentCost = double(payload["total_cost_usd"])
            ?? double(payload["cost_usd"])
            ?? transcriptSummary?.costUSD
        let model = string(payload["model"]) ?? transcriptSummary?.lastModel
        let finalDetail = detail
            ?? (type == .turnCompleted ? transcriptSummary?.lastAssistantText : nil)
        let toolFailed: Bool? = {
            guard type == .toolFinished else { return nil }
            if eventName.lowercased() == "posttoolusefailure" { return true }
            guard let response = payload["tool_response"] as? [String: Any] else { return nil }
            if response["is_error"] as? Bool == true { return true }
            if response["isError"] as? Bool == true { return true }
            if response["interrupted"] as? Bool == true { return true }
            if response["error"] != nil { return true }
            return false
        }()

        let event = AgentEvent(
            type: type,
            agent: agent,
            sessionId: bounded(sessionId, length: 160) ?? sessionId,
            parentSessionId: bounded(parentSessionId, length: 160),
            cwd: bounded(string(payload["cwd"]), length: 1_024),
            tool: bounded(tool, length: 160),
            detail: bounded(finalDetail, length: 2_000),
            terminal: terminalIdentity(environment: context.environment),
            tty: bounded(context.tty, length: 64),
            agentPid: context.agentPid,
            model: bounded(model, length: 80),
            transcriptPath: bounded(transcriptPath, length: 2_048),
            toolFailed: toolFailed,
            quotaUsed: double(payload["quota_used"]) ?? double(payload["quotaUsed"]),
            equivalentCostUSD: equivalentCost
        )

        let interaction: InteractionRequest?
        if context.suppressInteractions {
            interaction = nil
        } else if type == .permissionRequested {
            interaction = InteractionRequest(
                kind: .permission,
                providerEventName: eventName,
                title: "\(agent.displayName) requests permission",
                detail: detail
            )
        } else if type == .toolStarted, tool == "AskUserQuestion" {
            interaction = InteractionRequest(
                kind: .question,
                providerEventName: eventName,
                title: "\(agent.displayName) asks",
                detail: nil,
                questions: questions
            )
        } else if type == .toolStarted, tool == "ExitPlanMode" {
            let visiblePlan = bounded(string(toolInput["plan"]), length: 200_000)
            interaction = InteractionRequest(
                kind: .plan,
                providerEventName: eventName,
                title: "Review plan",
                detail: visiblePlan
            )
        } else {
            interaction = nil
        }

        return NormalizedHook(
            envelope: BridgeEnvelope(event: event, interaction: interaction),
            toolInput: toolInput
        )
    }

    public static func parseQuestions(_ value: Any?) -> [AgentQuestion] {
        guard let rawQuestions = value as? [[String: Any]] else { return [] }
        return rawQuestions.compactMap { raw in
            guard let question = string(raw["question"]) else { return nil }
            let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option -> QuestionOption? in
                guard let label = string(option["label"]) else { return nil }
                return QuestionOption(label: label, description: string(option["description"]))
            }
            return AgentQuestion(
                header: string(raw["header"]),
                question: question,
                options: options,
                multiSelect: (raw["multiSelect"] as? Bool) ?? false
            )
        }
    }

    public static func providerOutput(
        decision: InteractionDecision,
        interaction: InteractionRequest,
        toolInput: [String: Any]
    ) -> Data? {
        let specific: [String: Any]
        if interaction.providerEventName.caseInsensitiveCompare("PermissionRequest") == .orderedSame {
            var providerDecision: [String: Any] = ["behavior": decision.action.rawValue]
            if decision.action == .deny {
                providerDecision["message"] = decision.message ?? "Denied from NotchFlow"
            }
            specific = [
                "hookEventName": "PermissionRequest",
                "decision": providerDecision
            ]
        } else {
            var preTool: [String: Any] = [
                "hookEventName": "PreToolUse",
                "permissionDecision": decision.action.rawValue,
                "permissionDecisionReason": decision.message ?? "Answered from NotchFlow"
            ]
            if decision.action == .allow {
                var updatedInput = toolInput
                if interaction.kind == .question {
                    updatedInput["answers"] = decision.answers
                } else if interaction.kind == .plan {
                    updatedInput["plan"] = interaction.detail ?? ""
                }
                preTool["updatedInput"] = updatedInput
            }
            specific = preTool
        }
        return try? JSONSerialization.data(
            withJSONObject: ["hookSpecificOutput": specific],
            options: [.sortedKeys]
        )
    }

    public static func inferAgent(environment: [String: String]) -> AgentKind {
        if environment["CLAUDE_PROJECT_DIR"] != nil { return .claude }
        if environment["CODEX_HOME"] != nil { return .codex }
        return .unknown
    }

    public static func terminalIdentity(environment: [String: String]) -> String? {
        if environment["NOTCHFLOW_SESSION"] != nil { return "NotchFlow" }
        var program = environment["TERM_PROGRAM"]
        if program == nil, environment["KITTY_WINDOW_ID"] != nil { program = "kitty" }
        if program == nil, environment["ALACRITTY_WINDOW_ID"] != nil { program = "Alacritty" }
        let session = environment["TERM_SESSION_ID"]
            ?? environment["ITERM_SESSION_ID"]
            ?? environment["WARP_TERMINAL_SESSION_UUID"]
        return bounded([program, session].compactMap { $0 }.joined(separator: " · "), length: 240)
    }

    public static func bounded(_ value: String?, length: Int) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.prefix(length))
    }

    static func string(_ value: Any?) -> String? { value as? String }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
