import XCTest
import NotchFlowCore
@testable import NotchKit

/// Guards the quota-visibility rule — the class of bug where the "now" strip
/// silently shows only one provider (or none), which reads as "plenty of credit
/// left" when it isn't: this app's worst failure mode.
final class RelevantQuotasTests: XCTestCase {
    private func quota(_ provider: AgentKind, _ used: Double) -> QuotaState {
        QuotaState(provider: provider, usedFraction: used)
    }

    func testLiveProviderShownEvenAtLowUsage() {
        let claude = quota(.claude, 0.1)
        XCTAssertEqual(
            QuotaVisibility.relevant(all: [claude], liveProviders: [.claude], hottest: nil),
            [claude]
        )
    }

    func testIdleProviderHiddenBelowThreshold() {
        let codex = quota(.codex, 0.5)
        XCTAssertTrue(
            QuotaVisibility.relevant(all: [codex], liveProviders: [], hottest: nil).isEmpty
        )
    }

    func testIdleProviderShownAtEightyPercentBoundaryInclusive() {
        let codex = quota(.codex, 0.8)
        XCTAssertEqual(
            QuotaVisibility.relevant(all: [codex], liveProviders: [], hottest: nil),
            [codex]
        )
    }

    func testHottestFallbackWhenNothingQualifies() {
        let idle = quota(.claude, 0.3)
        XCTAssertEqual(
            QuotaVisibility.relevant(all: [idle], liveProviders: [], hottest: idle),
            [idle]
        )
    }

    func testEmptyWhenNothingQualifiesAndNoHottest() {
        XCTAssertTrue(
            QuotaVisibility.relevant(all: [], liveProviders: [], hottest: nil).isEmpty
        )
    }

    func testBothLiveProvidersAppearTogether() {
        let claude = quota(.claude, 0.2)
        let codex = quota(.codex, 0.1)
        let shown = QuotaVisibility.relevant(
            all: [claude, codex],
            liveProviders: [.claude, .codex],
            hottest: nil
        )
        XCTAssertEqual(Set(shown.map(\.provider)), [.claude, .codex])
    }
}
