import XCTest
@testable import NotchFlowCore

final class OpenAIPricingTests: XCTestCase {
    func testGpt5VariantsPriceOnCachedAwareTokens() {
        let pricing = OpenAIPricing.builtin
        // gpt-5.6-terra matches the flagship gpt-5 rule.
        let cost = pricing.cost(
            model: "gpt-5.6-terra",
            inputTokens: 1_000_000,
            cachedInput: 200_000,
            output: 100_000
        )
        // (800k @ 1.25 + 200k @ 0.125 + 100k @ 10) / 1e6 = 1 + 0.025 + 1 = 2.025
        XCTAssertEqual(cost ?? 0, 2.025, accuracy: 0.0001)
    }

    func testUnknownModelHasNoPriceSoItStaysTokens() {
        XCTAssertNil(OpenAIPricing.builtin.cost(
            model: "some-future-model", inputTokens: 1000, cachedInput: 0, output: 100
        ))
    }

    func testOverrideWinsButBuiltinRemainsFallback() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openai-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }
        try Data(#"[{"contains":["terra"],"rates":{"input":2,"cachedInput":0.2,"output":20}}]"#.utf8)
            .write(to: path)
        let pricing = OpenAIPricing.load(overridePath: path.path)
        XCTAssertEqual(pricing.rates(for: "gpt-5.6-terra")?.output, 20, "override applies")
        XCTAssertEqual(pricing.rates(for: "gpt-5.6-sol")?.output, 10, "builtin still covers other gpt-5")
    }

    func testCodexRolloutNowCarriesADollarCost() {
        let rollout = Data([
            #"{"timestamp":"2026-07-20T18:00:00.000Z","type":"session_meta","payload":{"cwd":"/Sites/toni"}}"#,
            #"{"timestamp":"2026-07-20T18:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"2026-07-20T18:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":14271,"cached_input_tokens":11008,"output_tokens":72}}}}"#
        ].joined(separator: "\n").utf8)
        let events = UsageAggregator.codexEvents(rollout: rollout, pricing: .builtin)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.provider, .codex)
        XCTAssertEqual(events.first?.model, "gpt-5.6-sol")
        XCTAssertGreaterThan(events.first?.costUSD ?? 0, 0, "Codex now prices instead of reporting $0")
    }
}
