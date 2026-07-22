import Foundation

/// Codex offers no hook surface its Desktop app honors: `notify` never
/// fires there (nor under `exec`) and that config slot commonly belongs to
/// another tool anyway. But every session, Desktop and TUI alike, streams
/// newline-delimited JSON into a rollout file under ~/.codex/sessions.
/// Each line maps onto the same events the hook bridge produces, so a
/// file tail becomes a full monitor with zero configuration.
public enum CodexRolloutMapper {
    /// Session id straight from the filename: rollout-<date>-<uuid>.jsonl.
    public static func sessionId(fromFilename name: String) -> String? {
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let stem = name.dropFirst("rollout-".count).dropLast(".jsonl".count)
        guard stem.count >= 36 else { return nil }
        return String(stem.suffix(36))
    }

    public static func events(fromLine line: Data, sessionId: String) -> [AgentEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let row = object as? [String: Any],
              let kind = row["type"] as? String else { return [] }
        let payload = row["payload"] as? [String: Any] ?? [:]
        let timestamp = (row["timestamp"] as? String).flatMap(date) ?? Date()

        func event(
            _ type: AgentEventType,
            tool: String? = nil,
            detail: String? = nil,
            cwd: String? = nil,
            terminal: String? = nil
        ) -> AgentEvent {
            AgentEvent(
                type: type,
                agent: .codex,
                sessionId: sessionId,
                cwd: cwd,
                tool: tool,
                detail: detail.flatMap { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : String(trimmed.prefix(2_000))
                },
                terminal: terminal,
                timestamp: timestamp
            )
        }

        switch kind {
        case "session_meta":
            let originator = (payload["originator"] as? String) ?? ""
            return [event(
                .sessionStarted,
                cwd: payload["cwd"] as? String,
                terminal: originator.lowercased().contains("desktop") ? "Codex Desktop" : nil
            )]
        case "event_msg":
            switch payload["type"] as? String {
            case "user_message":
                return [event(.promptSubmitted, detail: payload["message"] as? String)]
            case "task_complete":
                return [event(.turnCompleted, detail: payload["last_agent_message"] as? String)]
            case "turn_aborted":
                return [event(.turnCompleted, detail: "Interrupted")]
            case "patch_apply_end":
                // The patch result names every file it touched; replaying
                // them as Edit starts feeds the assignment's file count.
                let files = touchedFiles(stdout: payload["stdout"] as? String)
                guard !files.isEmpty else { return [event(.toolFinished)] }
                return files.map { event(.toolStarted, tool: "Edit", detail: $0) }
                    + [event(.toolFinished)]
            case "mcp_tool_call_end":
                return [event(.toolFinished)]
            default:
                return []
            }
        case "response_item":
            switch payload["type"] as? String {
            case "custom_tool_call":
                let input = (payload["input"] as? String)?
                    .split(separator: "\n").first.map { String($0.prefix(160)) }
                return [event(.toolStarted, tool: payload["name"] as? String, detail: input)]
            case "function_call":
                let arguments = (payload["arguments"] as? String).map { String($0.prefix(160)) }
                return [event(.toolStarted, tool: payload["name"] as? String, detail: arguments)]
            case "custom_tool_call_output", "function_call_output":
                return [event(.toolFinished)]
            default:
                return []
            }
        default:
            return []
        }
    }

    /// "Success. Updated the following files:\nA /path\nM /path" → paths.
    static func touchedFiles(stdout: String?) -> [String] {
        guard let stdout, stdout.hasPrefix("Success") else { return [] }
        let files = stdout.split(separator: "\n").dropFirst().compactMap { line -> String? in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, ["A", "M", "D"].contains(String(parts[0])) else { return nil }
            return String(parts[1])
        }
        return Array(files.prefix(8))
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    static func date(_ text: String) -> Date? {
        fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text)
    }
}
