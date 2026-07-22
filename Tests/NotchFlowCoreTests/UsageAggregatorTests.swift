import XCTest
@testable import NotchFlowCore

final class UsageAggregatorTests: XCTestCase {
    private func jsonl(_ rows: [[String: Any]]) -> Data {
        rows
            .map { try! JSONSerialization.data(withJSONObject: $0) }
            .map { String(data: $0, encoding: .utf8)! }
            .joined(separator: "\n")
            .data(using: .utf8)!
    }

    func testClaudeEventsDeduplicateAndPickUpProjectFromCwd() throws {
        let assistantRow: [String: Any] = [
            "type": "assistant",
            "timestamp": "2026-07-18T10:00:00Z",
            "cwd": "/Users/x/Sites/shop",
            "message": [
                "id": "m1",
                "model": "claude-fable-5",
                "usage": ["input_tokens": 1_000, "output_tokens": 200]
            ]
        ]
        let events = UsageAggregator.claudeEvents(
            transcript: jsonl([assistantRow, assistantRow]),
            fallbackProject: "fallback"
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.project, "shop")
        XCTAssertEqual(events.first?.model, "claude-fable-5")
        XCTAssertEqual(events.first?.input, 1_000)
        let expected = (1_000 * 10.0 + 200 * 50.0) / 1_000_000
        XCTAssertEqual(events.first?.costUSD ?? 0, expected, accuracy: 0.0001)
    }

    func testCodexRolloutUsesLastCumulativeSnapshotAndPrices() throws {
        let rows: [[String: Any]] = [
            ["timestamp": "2026-07-18T09:00:00Z", "payload": ["type": "session_meta", "cwd": "/Users/x/api", "model": "gpt-5.3-codex"]],
            ["payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 100, "output_tokens": 50]]]],
            ["payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 900, "output_tokens": 400]]]]
        ]
        let events = UsageAggregator.codexEvents(rollout: jsonl(rows), pricing: .builtin)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.input, 900)
        XCTAssertEqual(events.first?.output, 400)
        // (900 @ 1.25 + 400 @ 10) / 1e6 = 0.005125
        XCTAssertEqual(events.first?.costUSD ?? 0, 0.005125, accuracy: 0.000001)
        XCTAssertEqual(events.first?.project, "api")
    }

    func testSummarizeBucketsSortsAndFiltersByDate() throws {
        let old = UsageEvent(
            date: Date(timeIntervalSinceNow: -40 * 86_400),
            provider: .claude, model: "a", project: "p1",
            input: 10, output: 10, cacheRead: 0, cacheWrite: 0, costUSD: 1
        )
        let cheap = UsageEvent(
            date: Date(), provider: .claude, model: "a", project: "p1",
            input: 100, output: 10, cacheRead: 0, cacheWrite: 0, costUSD: 2
        )
        let expensive = UsageEvent(
            date: Date(), provider: .claude, model: "b", project: "p2",
            input: 100, output: 10, cacheRead: 0, cacheWrite: 0, costUSD: 9
        )

        let summary = UsageAggregator.summarize(
            [old, cheap, expensive],
            since: Date(timeIntervalSinceNow: -7 * 86_400)
        )

        XCTAssertEqual(summary.total.costUSD, 11, accuracy: 0.0001)
        XCTAssertEqual(summary.byModel.first?.model, "b")
        XCTAssertEqual(summary.byProject.first?.project, "p2")
        XCTAssertEqual(summary.byDay.count, 1)
    }

    func testForecastProjectsExhaustionOnlyWhenItBeatsTheReset() throws {
        let now = Date()
        let fastBurn = QuotaWindow(
            usedFraction: 0.6,
            durationMinutes: 300,
            resetsAt: now.addingTimeInterval(4 * 3_600)
        )
        XCTAssertNotNil(QuotaForecast.exhaustionDate(window: fastBurn, now: now))

        let slowBurn = QuotaWindow(
            usedFraction: 0.1,
            durationMinutes: 300,
            resetsAt: now.addingTimeInterval(600)
        )
        XCTAssertNil(QuotaForecast.exhaustionDate(window: slowBurn, now: now))
    }

    func testShortModelStripsPrefixAndDate() {
        XCTAssertEqual(UsageAggregator.shortModel("claude-haiku-4-5-20251001"), "haiku-4-5")
        XCTAssertEqual(UsageAggregator.shortModel("gpt-5.3-codex"), "gpt-5.3-codex")
    }
}
