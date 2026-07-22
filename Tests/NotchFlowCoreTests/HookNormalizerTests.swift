import XCTest
@testable import NotchFlowCore

final class HookNormalizerTests: XCTestCase {
    private func payload(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testClaudePreToolUseBashProducesToolStartedWithDetail() throws {
        let hook = HookNormalizer.normalize(
            input: payload([
                "hook_event_name": "PreToolUse",
                "session_id": "s1",
                "cwd": "/Projects/shop",
                "tool_name": "Bash",
                "tool_input": ["command": "npm test"]
            ]),
            context: HookContext(forcedAgent: .claude, environment: [:], tty: "ttys004")
        )

        let event = try XCTUnwrap(hook).envelope.event
        XCTAssertEqual(event.type, .toolStarted)
        XCTAssertEqual(event.agent, .claude)
        XCTAssertEqual(event.tool, "Bash")
        XCTAssertEqual(event.detail, "npm test")
        XCTAssertEqual(event.tty, "ttys004")
        XCTAssertNil(hook?.envelope.interaction)
    }

    func testPermissionRequestCreatesInteractionUnlessSuppressed() throws {
        let raw: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf build"]
        ]

        let interactive = HookNormalizer.normalize(
            input: payload(raw),
            context: HookContext(forcedAgent: .claude, environment: [:])
        )
        XCTAssertEqual(interactive?.envelope.interaction?.kind, .permission)
        XCTAssertEqual(interactive?.envelope.event.type, .permissionRequested)

        let suppressed = HookNormalizer.normalize(
            input: payload(raw),
            context: HookContext(forcedAgent: .claude, environment: [:], suppressInteractions: true)
        )
        XCTAssertNil(suppressed?.envelope.interaction)
        XCTAssertEqual(suppressed?.envelope.event.type, .permissionRequested)
    }

    func testAskUserQuestionParsesOptionsAndMultiSelect() throws {
        let hook = HookNormalizer.normalize(
            input: payload([
                "hook_event_name": "PreToolUse",
                "session_id": "s1",
                "tool_name": "AskUserQuestion",
                "tool_input": [
                    "questions": [[
                        "question": "Which database?",
                        "header": "Database",
                        "multiSelect": false,
                        "options": [
                            ["label": "SQLite", "description": "Zero config"],
                            ["label": "Postgres"]
                        ]
                    ]]
                ]
            ]),
            context: HookContext(forcedAgent: .claude, environment: [:])
        )

        let interaction = try XCTUnwrap(hook?.envelope.interaction)
        XCTAssertEqual(interaction.kind, .question)
        XCTAssertEqual(interaction.questions.count, 1)
        XCTAssertEqual(interaction.questions.first?.options.map(\.label), ["SQLite", "Postgres"])
        XCTAssertEqual(hook?.envelope.event.detail, "Which database?")
    }

    func testCodexTurnCompleteArrivesAsIdleTurn() throws {
        let hook = HookNormalizer.normalize(
            input: payload([
                "type": "agent-turn-complete",
                "thread-id": "t-9",
                "cwd": "/Projects/api"
            ]),
            context: HookContext(forcedAgent: .codex, environment: [:])
        )

        XCTAssertEqual(hook?.envelope.event.type, .turnCompleted)
        XCTAssertEqual(hook?.envelope.event.sessionId, "t-9")
    }

    func testUnknownEventReturnsNil() {
        XCTAssertNil(HookNormalizer.normalize(
            input: payload(["hook_event_name": "SomethingNew", "session_id": "x"]),
            context: HookContext(environment: [:])
        ))
    }

    func testPermissionAllowOutputUsesProviderDecisionShape() throws {
        let interaction = InteractionRequest(
            id: "r1",
            kind: .permission,
            providerEventName: "PermissionRequest",
            title: "Claude requests permission"
        )
        let output = try XCTUnwrap(HookNormalizer.providerOutput(
            decision: InteractionDecision(requestId: "r1", action: .allow),
            interaction: interaction,
            toolInput: [:]
        ))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: output) as? [String: Any]
        )
        let specific = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(specific["decision"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual(decision["behavior"] as? String, "allow")
    }

    func testQuestionAnswerInjectsAnswersIntoUpdatedInput() throws {
        let interaction = InteractionRequest(
            id: "r2",
            kind: .question,
            providerEventName: "PreToolUse",
            title: "Claude asks"
        )
        let output = try XCTUnwrap(HookNormalizer.providerOutput(
            decision: InteractionDecision(
                requestId: "r2",
                action: .allow,
                answers: ["Which database?": "SQLite"]
            ),
            interaction: interaction,
            toolInput: ["questions": []]
        ))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: output) as? [String: Any]
        )
        let specific = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        let updated = try XCTUnwrap(specific["updatedInput"] as? [String: Any])
        XCTAssertEqual(specific["permissionDecision"] as? String, "allow")
        XCTAssertEqual((updated["answers"] as? [String: String])?["Which database?"], "SQLite")
    }

    func testTerminalIdentityFallsBackToKittyEnvironment() {
        XCTAssertEqual(
            HookNormalizer.terminalIdentity(environment: ["KITTY_WINDOW_ID": "3"]),
            "kitty"
        )
        XCTAssertEqual(
            HookNormalizer.terminalIdentity(environment: [
                "TERM_PROGRAM": "iTerm.app",
                "ITERM_SESSION_ID": "w0t2p0:AAA"
            ]),
            "iTerm.app · w0t2p0:AAA"
        )
    }

    func testPricingPrefersOverrideRuleOrderAndDateWindows() {
        let pricing = ClaudePricing.builtin
        XCTAssertEqual(pricing.rates(for: "claude-fable-5")?.input, 10)
        XCTAssertEqual(pricing.rates(for: "claude-opus-4-8")?.input, 5)
        let before = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!
        let after = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        XCTAssertEqual(pricing.rates(for: "claude-sonnet-5", now: before)?.input, 2)
        XCTAssertEqual(pricing.rates(for: "claude-sonnet-5", now: after)?.input, 3)
        XCTAssertNil(pricing.rates(for: "gpt-9"))
    }

    func testTranscriptCostDeduplicatesByMessageId() throws {
        let line: [String: Any] = [
            "type": "assistant",
            "message": [
                "id": "m1",
                "model": "claude-fable-5",
                "usage": ["input_tokens": 1_000, "output_tokens": 500]
            ]
        ]
        let data = [line, line]
            .map { try! JSONSerialization.data(withJSONObject: $0) }
            .map { String(data: $0, encoding: .utf8)! }
            .joined(separator: "\n")
            .data(using: .utf8)!

        let cost = try XCTUnwrap(TranscriptCost.claudeEquivalentCost(transcript: data))
        XCTAssertEqual(cost, (1_000 * 10 + 500 * 50) / 1_000_000, accuracy: 0.0001)
    }
}
