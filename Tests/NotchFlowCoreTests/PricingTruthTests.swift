import XCTest
@testable import NotchFlowCore

final class PricingTruthTests: XCTestCase {
    private func transcriptLine(model: String, id: String, output: Int) -> String {
        #"{"type":"assistant","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":100,"output_tokens":\#(output)}}}"#
    }

    func testUnknownModelsAreNamedInsteadOfSilentlyCostingZero() {
        let transcript = Data([
            transcriptLine(model: "claude-opus-4-8", id: "m1", output: 1_000_000),
            transcriptLine(model: "claude-nova-9", id: "m2", output: 1_000_000),
            transcriptLine(model: "<synthetic>", id: "m3", output: 5)
        ].joined(separator: "\n").utf8)

        let breakdown = TranscriptCost.claudeCostBreakdown(transcript: transcript)
        XCTAssertEqual(breakdown.unpricedModels, ["claude-nova-9"])
        XCTAssertEqual(breakdown.costUSD ?? 0, 25.0005, accuracy: 0.001, "known rows still price")
    }

    func testPricingOverrideKeepsBuiltinAsFallback() throws {
        let override = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchflow-pricing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: override) }
        try Data(#"""
        [{"contains":["nova-9"],"rates":{"input":7,"cache5m":8,"cache1h":9,"cacheRead":1,"output":30}}]
        """#.utf8).write(to: override)

        let pricing = ClaudePricing.load(overridePath: override.path)
        XCTAssertEqual(pricing.rates(for: "claude-nova-9")?.output, 30, "override rule applies")
        XCTAssertEqual(
            pricing.rates(for: "claude-opus-4-8")?.output, 25,
            "builtin table must survive a partial override"
        )
    }

    func testLiveCostUpdatesWorkingSessionWithoutTouchingState() {
        var reducer = SessionReducer()
        reducer.apply(AgentEvent(
            type: .toolStarted, agent: .claude, sessionId: "s1",
            tool: "Bash", detail: "npm test"
        ))
        let before = reducer.sessions["s1"]!

        reducer.applyLiveCost(sessionId: "s1", costUSD: 1.23, costIncomplete: true)
        let after = reducer.sessions["s1"]!
        XCTAssertEqual(after.equivalentCostUSD, 1.23)
        XCTAssertEqual(after.costIncomplete, true)
        XCTAssertEqual(after.status, before.status)
        XCTAssertEqual(after.updatedAt, before.updatedAt)
        XCTAssertEqual(after.detail, before.detail)
    }

    func testAuthProblemQuotaNeverDrivesTheHeatAndRoundTrips() throws {
        var reducer = SessionReducer()
        reducer.applyQuota(QuotaState(provider: .codex, usedFraction: 0.4))
        reducer.applyQuota(QuotaState(provider: .claude, authProblem: true))
        XCTAssertEqual(reducer.hottestQuota()?.provider, .codex)

        let restored = try JSONDecoder().decode(
            QuotaState.self,
            from: JSONEncoder().encode(QuotaState(provider: .claude, authProblem: true))
        )
        XCTAssertEqual(restored.authProblem, true)
    }
}
