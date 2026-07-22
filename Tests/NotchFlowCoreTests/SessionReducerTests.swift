import XCTest
@testable import NotchFlowCore

final class SessionReducerTests: XCTestCase {
    func testPermissionMovesSessionToAttentionState() {
        var reducer = SessionReducer()
        reducer.apply(AgentEvent(
            type: .toolStarted,
            agent: .claude,
            sessionId: "s1",
            tool: "Bash",
            detail: "npm test"
        ))
        reducer.apply(AgentEvent(
            type: .permissionRequested,
            agent: .claude,
            sessionId: "s1",
            tool: "Bash",
            detail: "npm test"
        ))

        XCTAssertEqual(reducer.sessions["s1"]?.status, .waitingPermission)
        XCTAssertEqual(reducer.sessions["s1"]?.tool, "Bash")
    }

    func testSubagentKeepsParentRelationship() {
        var reducer = SessionReducer()
        reducer.apply(AgentEvent(
            type: .subagentStarted,
            agent: .codex,
            sessionId: "child",
            parentSessionId: "parent"
        ))

        XCTAssertEqual(reducer.sessions["child"]?.parentId, "parent")
        XCTAssertEqual(reducer.sessions["child"]?.status, .working)
    }

    func testQuotaIsClampedAndToneGetsHotter() {
        var reducer = SessionReducer()
        reducer.apply(AgentEvent(
            type: .quotaUpdated,
            agent: .codex,
            sessionId: "quota",
            quotaUsed: 1.4
        ))

        XCTAssertEqual(reducer.quotas[.codex]?.usedFraction, 1)
        XCTAssertGreaterThan(QuotaTone.forUsage(0.9).red, QuotaTone.forUsage(0.4).red)
        XCTAssertEqual(QuotaTone.forUsage(1).red, 1, accuracy: 0.0001)
    }

    func testProvidersKeepIndependentQuotasAndHottestWins() {
        var reducer = SessionReducer()
        reducer.applyQuota(QuotaState(provider: .codex, usedFraction: 0.3))
        reducer.applyQuota(QuotaState(provider: .claude, usedFraction: 0.8))

        XCTAssertEqual(reducer.quotas.count, 2)
        XCTAssertEqual(reducer.hottestQuota()?.provider, .claude)

        reducer.applyQuota(QuotaState(
            provider: .claude,
            usedFraction: 0.1,
            updatedAt: Date().addingTimeInterval(-3_600)
        ))
        XCTAssertEqual(reducer.quotas[.claude]?.usedFraction, 0.8, "stale update must not win")
    }

    func testTurnCompletedBecomesIdleThenExpiresToCompleted() {
        var reducer = SessionReducer()
        let past = Date().addingTimeInterval(-2_000)
        reducer.apply(AgentEvent(
            type: .turnCompleted,
            agent: .claude,
            sessionId: "s1",
            timestamp: past
        ))
        XCTAssertEqual(reducer.sessions["s1"]?.status, .idle)

        reducer.expireSessions(idleAfter: 1_800, removeAfter: 7_200)
        XCTAssertEqual(reducer.sessions["s1"]?.status, .completed)
    }

    func testQuotaUsesHottestRealWindowAndRoundTrips() throws {
        let quota = QuotaState(
            provider: .codex,
            primary: QuotaWindow(usedFraction: 0.22, durationMinutes: 300),
            secondary: QuotaWindow(usedFraction: 0.72, durationMinutes: 10_080),
            planName: "plus"
        )

        XCTAssertEqual(quota.usedFraction, 0.72)
        let restored = try JSONDecoder().decode(
            QuotaState.self,
            from: JSONEncoder().encode(quota)
        )
        XCTAssertEqual(restored, quota)
    }

    func testToolCompletionReturnsSessionToWorking() {
        var reducer = SessionReducer()
        reducer.apply(AgentEvent(
            type: .toolStarted,
            agent: .codex,
            sessionId: "s1",
            tool: "apply_patch"
        ))
        reducer.apply(AgentEvent(
            type: .toolFinished,
            agent: .codex,
            sessionId: "s1"
        ))

        XCTAssertEqual(reducer.sessions["s1"]?.status, .working)
        XCTAssertNil(reducer.sessions["s1"]?.tool)
    }

    func testRepeatingCommandAndChainedFailuresReadAsStuck() {
        var reducer = SessionReducer()
        for _ in 0..<3 {
            reducer.apply(AgentEvent(
                type: .toolStarted, agent: .claude, sessionId: "s1",
                tool: "Bash", detail: "npm test"
            ))
            reducer.apply(AgentEvent(type: .toolFinished, agent: .claude, sessionId: "s1"))
        }
        XCTAssertNotNil(reducer.sessions["s1"]?.stuckReason)
        XCTAssertTrue(reducer.sessions["s1"]?.stuckReason?.contains("3x Bash") == true)

        reducer.apply(AgentEvent(
            type: .toolStarted, agent: .claude, sessionId: "s1",
            tool: "Edit", detail: "src/a.swift"
        ))
        reducer.apply(AgentEvent(type: .toolFinished, agent: .claude, sessionId: "s1"))
        XCTAssertNil(reducer.sessions["s1"]?.stuckReason, "progress clears the verdict")

        var failing = SessionReducer()
        for file in ["a", "b"] {
            failing.apply(AgentEvent(
                type: .toolStarted, agent: .claude, sessionId: "s2",
                tool: "Bash", detail: "build \(file)"
            ))
            failing.apply(AgentEvent(
                type: .toolFinished, agent: .claude, sessionId: "s2", toolFailed: true
            ))
        }
        XCTAssertTrue(failing.sessions["s2"]?.stuckReason?.contains("failures") == true)
    }

    func testFilesTouchedAccumulatePerAssignmentAndResetOnNewPrompt() {
        var reducer = SessionReducer()
        for (tool, path) in [
            ("Edit", "Sources/a.swift"),
            ("Write", "Sources/b.swift"),
            ("Edit", "Sources/a.swift"),
            ("Read", "Sources/c.swift")
        ] {
            reducer.apply(AgentEvent(
                type: .toolStarted, agent: .claude, sessionId: "s1",
                tool: tool, detail: path
            ))
            reducer.apply(AgentEvent(type: .toolFinished, agent: .claude, sessionId: "s1"))
        }
        XCTAssertEqual(
            reducer.sessions["s1"]?.filesTouched,
            ["Sources/a.swift", "Sources/b.swift"],
            "edits dedupe, reads never count"
        )

        reducer.apply(AgentEvent(
            type: .promptSubmitted, agent: .claude, sessionId: "s1", detail: "next task"
        ))
        XCTAssertEqual(reducer.sessions["s1"]?.filesTouched, [])
        XCTAssertNotNil(reducer.sessions["s1"]?.promptedAt)
    }

    func testExpireKeepsUnreviewedFinishedSessions() {
        var reducer = SessionReducer()
        let old = Date().addingTimeInterval(-10_000)
        for id in ["seen", "unseen"] {
            reducer.apply(AgentEvent(
                type: .sessionStopped, agent: .claude, sessionId: id,
                detail: "done", timestamp: old
            ))
        }
        reducer.expireSessions(keeping: ["unseen"])
        XCTAssertNil(reducer.sessions["seen"])
        XCTAssertNotNil(reducer.sessions["unseen"], "an unreviewed outcome must not vanish")
    }

    func testStalePidlessWorkingSessionIsReapedButPidAndFreshOnesSurvive() {
        var reducer = SessionReducer()
        let old = Date().addingTimeInterval(-2_000)

        // PID-less (transcript/rollout) session stuck working with no closing
        // event: the backstop must reap it.
        reducer.apply(AgentEvent(
            type: .toolStarted, agent: .codex, sessionId: "zombie",
            tool: "exec", detail: "build", timestamp: old
        ))
        // A hook session (has a PID) is liveness-managed, never time-reaped.
        reducer.apply(AgentEvent(
            type: .toolStarted, agent: .claude, sessionId: "hooked",
            tool: "Bash", detail: "npm test", agentPid: 4242, timestamp: old
        ))
        // A PID-less session that is still fresh must be left alone.
        reducer.apply(AgentEvent(
            type: .toolStarted, agent: .codex, sessionId: "fresh",
            tool: "exec", detail: "lint"
        ))

        reducer.expireSessions(staleWorkingAfter: 900)
        XCTAssertEqual(reducer.sessions["zombie"]?.status, .completed)
        XCTAssertEqual(reducer.sessions["hooked"]?.status, .runningTool, "PID sessions stay for liveness")
        XCTAssertEqual(reducer.sessions["fresh"]?.status, .runningTool, "recent silence is not a zombie")
    }

    func testHookNamesAreExplicitAndUnknownEventsAreIgnored() {
        XCTAssertEqual(AgentEventType.fromHookName("Stop"), .turnCompleted)
        XCTAssertEqual(AgentEventType.fromHookName("SessionEnd"), .sessionStopped)
        XCTAssertEqual(AgentEventType.fromHookName("PreToolUse"), .toolStarted)
        XCTAssertEqual(AgentEventType.fromHookName("agent-turn-complete"), .turnCompleted)
        XCTAssertNil(AgentEventType.fromHookName("FutureProviderEvent"))
    }

    func testLateEventDoesNotReviveCompletedSession() {
        var reducer = SessionReducer()
        let finishedAt = Date()
        reducer.apply(AgentEvent(
            type: .sessionStopped,
            agent: .codex,
            sessionId: "s1",
            timestamp: finishedAt
        ))
        reducer.apply(AgentEvent(
            type: .toolStarted,
            agent: .codex,
            sessionId: "s1",
            timestamp: finishedAt.addingTimeInterval(-10)
        ))

        XCTAssertEqual(reducer.sessions["s1"]?.status, .completed)
    }

    func testHookMergeRemovesOnlyOwnedHandlerFromMixedGroup() {
        let groups: [[String: Any]] = [[
            "matcher": "Bash",
            "hooks": [
                ["type": "command", "command": "/tmp/notchflow-hook --agent claude"],
                ["type": "command", "command": "/usr/local/bin/user-hook"]
            ]
        ]]

        let result = HookConfigurationMerger.removingOwnedHandlers(
            from: groups,
            commandMarker: "notchflow-hook"
        )
        let handlers = result.first?["hooks"] as? [[String: Any]]
        XCTAssertEqual(result.first?["matcher"] as? String, "Bash")
        XCTAssertEqual(handlers?.count, 1)
        XCTAssertEqual(handlers?.first?["command"] as? String, "/usr/local/bin/user-hook")
    }
}
