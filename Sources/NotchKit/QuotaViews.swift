import SwiftUI
import NotchFlowCore

/// Which provider quotas the expanded "now" strip shows. Pure, so the rule can
/// be tested without a running view: a quota appears when its provider is
/// currently live, or when any window is ≥80% spent even if idle (so a
/// nearly-exhausted window never hides); with nothing qualifying it falls back
/// to the single hottest quota. Mirrors `NotchIslandView.relevantQuotas`.
enum QuotaVisibility {
    static func relevant(
        all: [QuotaState],
        liveProviders: Set<AgentKind>,
        hottest: QuotaState?
    ) -> [QuotaState] {
        let rows = all.filter { liveProviders.contains($0.provider) || $0.usedFraction >= 0.8 }
        if rows.isEmpty, let hottest { return [hottest] }
        return rows
    }
}

/// One dense, readable line per provider: bold window names, percentage in
/// the health color, reset time dimmed. Modeled on what actually reads well
/// at a glance instead of a boxed table.
struct QuotaStripView: View {
    let quotas: [QuotaState]

    var body: some View {
        // One compact line: each provider labeled by name in its own color, so
        // Claude vs Codex is obvious without stacking onto two rows.
        HStack(spacing: 14) {
            ForEach(quotas, id: \.provider) { quota in
                HStack(spacing: 6) {
                    if let logo = providerLogo(quota.provider) {
                        logo.resizable().scaledToFit().frame(height: 13)
                    } else {
                        Text(quota.provider.displayName)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(agentColor(quota.provider))
                    }
                    if quota.authProblem == true {
                        Text("signed out")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.28))
                    } else {
                        windowsView(for: quota)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func windowsView(for quota: QuotaState) -> some View {
        let windows: [(String, QuotaWindow)] = [
            quota.primary.map { (label(minutes: $0.durationMinutes, fallback: "5h"), $0) },
            quota.secondary.map { (label(minutes: $0.durationMinutes, fallback: "7d"), $0) }
        ].compactMap { $0 }
        HStack(spacing: 8) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 3) {
                    Text(entry.0)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                    Text("\(Int((entry.1.usedFraction * 100).rounded()))%")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(usageColor(entry.1.usedFraction))
                }
            }
        }
    }

    private func label(minutes: Int?, fallback: String) -> String {
        guard let minutes else { return fallback }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return fallback
    }
}
