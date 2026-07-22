import SwiftUI
import Charts
import NotchFlowCore

/// What was the work worth, and where did it go — value first, then the trend,
/// then the breakdown. A chart over a wall of numbers.
public struct StatsView: View {
    @ObservedObject var usage: UsageStore
    @State private var range: StatsRange = .week

    public init(usage: UsageStore) { self.usage = usage }
    @State private var shownTotal: Double = 0
    @State private var barsGrown = false

    enum StatsRange: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7d"
        case month = "30d"
        var id: String { rawValue }

        var since: Date {
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())
            switch self {
            case .today: return startOfToday
            case .week: return calendar.date(byAdding: .day, value: -6, to: startOfToday)!
            case .month: return calendar.date(byAdding: .day, value: -29, to: startOfToday)!
            }
        }
    }

    private var summary: UsageSummary {
        UsageAggregator.summarize(usage.events, since: range.since)
    }

    public var body: some View {
        let summary = self.summary
        VStack(alignment: .leading, spacing: 14) {
            rangePicker
            hero(summary)
            if range != .today {
                spendChart(summary)
            }
            whereItGoes(summary)
        }
        .onAppear {
            shownTotal = 0
            withAnimation(.easeOut(duration: 0.9)) { shownTotal = self.summary.total.costUSD }
        }
        .onChange(of: range) { _, _ in
            shownTotal = 0
            withAnimation(.easeOut(duration: 0.9)) { shownTotal = self.summary.total.costUSD }
        }
        .onChange(of: summary.total.costUSD) { _, newValue in
            withAnimation(.easeOut(duration: 0.6)) { shownTotal = newValue }
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 5) {
            ForEach(StatsRange.allCases) { option in
                Button {
                    range = option
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(range == option ? 0.16 : 0.05)))
                        .foregroundStyle(.white.opacity(range == option ? 0.95 : 0.5))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let refreshed = usage.lastRefresh {
                Text("updated \(refreshed, format: .dateTime.hour().minute())")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
    }

    // MARK: - What was it worth

    private func hero(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if summary.total.costUSD == 0 {
                Text("\(compact(summary.total.totalTokens)) tokens")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: summary.total.totalTokens))
            } else {
                Text(shownTotal, format: .currency(code: "USD"))
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: shownTotal))
            }
            Text(summary.total.costUSD == 0 ? "of work, no per-token billing" : "of work, at API list prices")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
            Label("Covered by your subscription. No per-token bills.", systemImage: "checkmark.seal.fill")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.4, green: 0.88, blue: 0.6))
                .padding(.top, 1)
            if summary.byProvider.count > 1 {
                Rectangle()
                    .fill(.white.opacity(0.07))
                    .frame(height: 1)
                    .padding(.top, 9)
                HStack(spacing: 12) {
                    ForEach(summary.byProvider.sorted { $0.key.rawValue < $1.key.rawValue }, id: \.key) { provider, bucket in
                        HStack(spacing: 5) {
                            AgentChip(agent: provider)
                            if bucket.costUSD > 0 {
                                Text(bucket.costUSD, format: .currency(code: "USD"))
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .monospacedDigit()
                                    .contentTransition(.numericText(value: bucket.costUSD))
                            } else {
                                Text("\(compact(bucket.totalTokens)) tok")
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                }
                .padding(.top, 7)
            }
            if summary.total.totalTokens > 0 {
                Text("\(compact(summary.total.totalTokens)) tokens total")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.08), Color(red: 0.3, green: 0.8, blue: 0.55).opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: - Daily trend

    private func spendChart(_ s: UsageSummary) -> some View {
        let days = dailyCosts(s)
        let usesCost = s.total.costUSD > 0
        let pts = days.map { (day: $0.day, v: usesCost ? $0.cost : $0.tokens, today: $0.isToday) }
        let peak = max(pts.map(\.v).max() ?? 0, usesCost ? 0.01 : 1)
        let avg = pts.map(\.v).reduce(0, +) / Double(max(pts.count, 1))
        let today = pts.last
        let accent = Color(red: 0.4, green: 0.88, blue: 0.6)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Daily")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(usesCost ? "avg \(avg.formatted(.currency(code: "USD")))/day" : "avg \(compact(avg)) tok/day")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Chart {
                ForEach(pts, id: \.day) { p in
                    AreaMark(x: .value("Day", p.day, unit: .day), y: .value("v", p.v))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            .linearGradient(
                                colors: [accent.opacity(0.28), accent.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    LineMark(x: .value("Day", p.day, unit: .day), y: .value("v", p.v))
                        .interpolationMethod(.monotone)
                        .lineStyle(.init(lineWidth: 1.5, lineCap: .round))
                        .foregroundStyle(accent.opacity(0.85))
                }
                if let t = today, t.v > 0 {
                    PointMark(x: .value("Day", t.day, unit: .day), y: .value("v", t.v))
                        .symbolSize(60)
                        .foregroundStyle(accent)
                        .annotation(
                            position: .top,
                            spacing: 3,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            Text(usesCost ? t.v.formatted(.currency(code: "USD")) : compact(t.v))
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...(peak * 1.28))
            .frame(height: 50)
            .mask(alignment: .leading) {
                GeometryReader { g in
                    Rectangle().frame(width: g.size.width * (barsGrown ? 1 : 0))
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.035)))
        .onAppear { withAnimation(.easeOut(duration: 0.7)) { barsGrown = true } }
        .onChange(of: range) { _, _ in
            barsGrown = false
            withAnimation(.easeOut(duration: 0.7)) { barsGrown = true }
        }
    }

    private func dailyCosts(_ summary: UsageSummary) -> [(day: Date, cost: Double, tokens: Double, isToday: Bool)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let byDay = Dictionary(
            summary.byDay.map { (calendar.startOfDay(for: $0.day), $0.bucket.costUSD) },
            uniquingKeysWith: +
        )
        let tok = Dictionary(
            summary.byDay.map { (calendar.startOfDay(for: $0.day), $0.bucket.totalTokens) },
            uniquingKeysWith: +
        )
        var result: [(Date, Double, Double, Bool)] = []
        var day = calendar.startOfDay(for: range.since)
        while day <= today {
            result.append((day, byDay[day] ?? 0, tok[day] ?? 0, calendar.isDate(day, inSameDayAs: today)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    // MARK: - Where it goes

    private struct Slice: Identifiable {
        let id = UUID()
        let name: String
        let value: Double
        let display: String
        let other: Bool
    }

    private func slices(_ s: UsageSummary) -> (rows: [Slice], priced: Bool) {
        let priced = !s.byProject.isEmpty && s.byProject.allSatisfy { $0.bucket.costUSD > 0 }
        func mag(_ b: UsageBucket) -> Double { priced ? b.costUSD : b.totalTokens }
        func lab(_ c: Double, _ t: Double) -> String {
            priced ? c.formatted(.currency(code: "USD")) : "\(compact(t)) tok"
        }
        // Rank by the magnitude we actually chart — byProject is not guaranteed sorted.
        let sorted = s.byProject.sorted { mag($0.bucket) > mag($1.bucket) }
        var rows = sorted.prefix(5).map {
            Slice(name: $0.project, value: mag($0.bucket), display: lab($0.bucket.costUSD, $0.bucket.totalTokens), other: false)
        }
        let rest = sorted.dropFirst(5)
        if !rest.isEmpty {
            rows.append(
                Slice(
                    name: "Other",
                    value: rest.map { mag($0.bucket) }.reduce(0, +),
                    display: lab(rest.map { $0.bucket.costUSD }.reduce(0, +), rest.map { $0.bucket.totalTokens }.reduce(0, +)),
                    other: true
                )
            )
        }
        // Final descending order (Other included) so bar lengths read monotonic.
        rows.sort { $0.value > $1.value }
        return (rows, priced)
    }

    private func whereItGoes(_ s: UsageSummary) -> some View {
        let (rows, priced) = slices(s)
        let hue = Color(red: 0.4, green: 0.88, blue: 0.6)
        let maxV = max(rows.map(\.value).max() ?? 1, 0.01)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Where it goes")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                if !priced {
                    Text("by tokens")
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            // A ranked bar per project: name column, one shared-scale bar so
            // lengths compare directly, value column. Reads far better than a
            // Swift Charts axis chart at this tiny size.
            VStack(spacing: 7) {
                ForEach(rows) { row in
                    HStack(spacing: 9) {
                        Text(row.name)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(row.other ? .white.opacity(0.5) : .white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 84, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.05))
                                Capsule()
                                    .fill(row.other ? Color.white.opacity(0.22) : hue)
                                    .frame(width: max(3, proxy.size.width * min(row.value / maxV, 1) * (barsGrown ? 1 : 0)))
                            }
                        }
                        .frame(height: 8)
                        Text(row.display)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(width: 74, alignment: .trailing)
                    }
                }
            }
            if !s.byModel.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(s.byModel.prefix(3)), id: \.model) { e in
                        HStack(spacing: 4) {
                            ModelChip(model: e.model)
                            if e.bucket.costUSD > 0 {
                                Text(e.bucket.costUSD, format: .currency(code: "USD"))
                                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                        }
                    }
                }
                .padding(.top, 3)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.035)))
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { barsGrown = true } }
    }

    // MARK: - Helpers

    private func compact(_ value: Double) -> String {
        switch value {
        case 1_000_000_000...: return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        case 1_000...: return String(format: "%.0fk", value / 1_000)
        default: return String(format: "%.0f", value)
        }
    }
}
