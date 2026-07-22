import Foundation

/// Turns Claude Code transcript lines into bridge events, so the monitor
/// works with zero setup when the hooks are not installed. Claude Code
/// writes `~/.claude/projects/<project>/<session-uuid>.jsonl` for every
/// session; tailing it recovers the prompt, the tools it runs and their
/// outcomes without any hook. Interactivity (answering permissions and
/// questions) still needs the hooks; this is the read-only floor.
public enum ClaudeTranscriptMapper {
    /// The filename is the session id: `<uuid>.jsonl`.
    public static func sessionId(fromFilename name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(".jsonl".count))
        return stem.isEmpty ? nil : stem
    }

    public static func events(
        fromLine line: Data,
        sessionId fallbackId: String,
        transcriptPath: String
    ) -> [AgentEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let row = object as? [String: Any],
              let type = row["type"] as? String else { return [] }
        // Subagent (sidechain) activity is left to the hook path; the
        // transcript floor tracks the main conversation only.
        if row["isSidechain"] as? Bool == true { return [] }
        let sessionId = (row["sessionId"] as? String) ?? fallbackId
        let cwd = row["cwd"] as? String
        let timestamp = (row["timestamp"] as? String).flatMap(date) ?? Date()

        func event(
            _ type: AgentEventType,
            tool: String? = nil,
            detail: String? = nil,
            model: String? = nil,
            toolFailed: Bool? = nil
        ) -> AgentEvent {
            AgentEvent(
                type: type,
                agent: .claude,
                sessionId: sessionId,
                cwd: cwd,
                tool: tool,
                detail: detail.flatMap { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : String(trimmed.prefix(2_000))
                },
                model: model,
                transcriptPath: transcriptPath,
                toolFailed: toolFailed,
                timestamp: timestamp
            )
        }

        switch type {
        case "user":
            guard let message = row["message"] as? [String: Any] else { return [] }
            if let text = message["content"] as? String {
                return [event(.promptSubmitted, detail: text)].filter { $0.detail != nil }
            }
            if let blocks = message["content"] as? [[String: Any]] {
                let results = blocks.filter { $0["type"] as? String == "tool_result" }
                if !results.isEmpty {
                    let failed = results.contains { $0["is_error"] as? Bool == true }
                    return [event(.toolFinished, toolFailed: failed ? true : nil)]
                }
                let text = blocks
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: " ")
                let prompt = event(.promptSubmitted, detail: text)
                return prompt.detail == nil ? [] : [prompt]
            }
            return []
        case "assistant":
            guard let message = row["message"] as? [String: Any] else { return [] }
            let model = message["model"] as? String
            let blocks = message["content"] as? [[String: Any]] ?? []
            let toolUses = blocks.filter { $0["type"] as? String == "tool_use" }
            return toolUses.map { block in
                let input = block["input"] as? [String: Any] ?? [:]
                let detail = [
                    "command", "file_path", "path", "pattern", "url", "description", "prompt"
                ].lazy.compactMap { input[$0] as? String }.first
                return event(.toolStarted, tool: block["name"] as? String, detail: detail, model: model)
            }
        default:
            return []
        }
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
