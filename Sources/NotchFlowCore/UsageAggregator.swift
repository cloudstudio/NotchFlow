import Foundation

public struct UsageEvent: Codable, Equatable, Sendable {
    public let date: Date
    public let provider: AgentKind
    public let model: String
    public let project: String
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double
    public let costUSD: Double

    public init(
        date: Date,
        provider: AgentKind,
        model: String,
        project: String,
        input: Double,
        output: Double,
        cacheRead: Double,
        cacheWrite: Double,
        costUSD: Double
    ) {
        self.date = date
        self.provider = provider
        self.model = model
        self.project = project
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.costUSD = costUSD
    }
}

public struct UsageBucket: Codable, Equatable, Sendable {
    public var input: Double = 0
    public var output: Double = 0
    public var cacheRead: Double = 0
    public var cacheWrite: Double = 0
    public var costUSD: Double = 0

    public init() {}

    public mutating func add(_ event: UsageEvent) {
        input += event.input
        output += event.output
        cacheRead += event.cacheRead
        cacheWrite += event.cacheWrite
        costUSD += event.costUSD
    }

    public var totalTokens: Double { input + output + cacheRead + cacheWrite }
}

public struct UsageSummary: Equatable, Sendable {
    public var total = UsageBucket()
    public var byProvider: [AgentKind: UsageBucket] = [:]
    public var byModel: [(model: String, bucket: UsageBucket)] = []
    public var byProject: [(project: String, bucket: UsageBucket)] = []
    public var byDay: [(day: Date, bucket: UsageBucket)] = []

    public static func == (lhs: UsageSummary, rhs: UsageSummary) -> Bool {
        lhs.total == rhs.total
            && lhs.byProvider == rhs.byProvider
            && lhs.byModel.map(\.model) == rhs.byModel.map(\.model)
            && lhs.byModel.map(\.bucket) == rhs.byModel.map(\.bucket)
            && lhs.byProject.map(\.project) == rhs.byProject.map(\.project)
            && lhs.byProject.map(\.bucket) == rhs.byProject.map(\.bucket)
            && lhs.byDay.map(\.day) == rhs.byDay.map(\.day)
            && lhs.byDay.map(\.bucket) == rhs.byDay.map(\.bucket)
    }
}

public enum UsageAggregator {
    /// Parses a Claude Code transcript into per-message usage events,
    /// deduplicated by message id (last occurrence wins, matching how the
    /// CLI rewrites streamed messages).
    public static func claudeEvents(
        transcript: Data,
        fallbackProject: String,
        pricing: ClaudePricing = .builtin,
        now: Date = Date()
    ) -> [UsageEvent] {
        var byMessage: [String: UsageEvent] = [:]
        var order: [String] = []
        var project = fallbackProject
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for rawLine in transcript.split(separator: 0x0A) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any] else {
                continue
            }
            if project == fallbackProject, let cwd = row["cwd"] as? String, !cwd.isEmpty {
                project = URL(fileURLWithPath: cwd).lastPathComponent
            }
            guard row["type"] as? String == "assistant",
                  let message = row["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  let usage = message["usage"] as? [String: Any],
                  let rates = pricing.rates(for: model, now: now) else { continue }

            let timestamp = (row["timestamp"] as? String).flatMap {
                iso.date(from: $0) ?? isoPlain.date(from: $0)
            } ?? now
            let identity = (message["id"] as? String) ?? (row["uuid"] as? String) ?? UUID().uuidString
            let input = number(usage["input_tokens"])
            let output = number(usage["output_tokens"])
            let cacheRead = number(usage["cache_read_input_tokens"])
            let cacheWrite = number(usage["cache_creation_input_tokens"])
            let cacheBreakdown = usage["cache_creation"] as? [String: Any] ?? [:]
            let cache1h = number(cacheBreakdown["ephemeral_1h_input_tokens"])
            let cache5m = (cacheBreakdown["ephemeral_5m_input_tokens"]).map { number($0) }
                ?? max(0, cacheWrite - cache1h)
            let geoMultiplier = usage["inference_geo"] as? String == "us" ? 1.1 : 1.0
            let cost = geoMultiplier * (
                input * rates.input + output * rates.output +
                cacheRead * rates.cacheRead + cache1h * rates.cache1h + cache5m * rates.cache5m
            ) / 1_000_000

            if byMessage[identity] == nil { order.append(identity) }
            byMessage[identity] = UsageEvent(
                date: timestamp,
                provider: .claude,
                model: model,
                project: project,
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                costUSD: cost
            )
        }
        return order.compactMap { byMessage[$0] }
    }

    /// A Codex rollout logs cumulative token counters; the last snapshot is
    /// the file's total. Tokens only: there is no honest cost equivalence.
    public static func codexEvents(
        rollout: Data,
        pricing: OpenAIPricing = .load(),
        now: Date = Date()
    ) -> [UsageEvent] {
        var project = "codex"
        var model = "codex"
        var timestamp = now
        var last: [String: Any]?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for rawLine in rollout.split(separator: 0x0A) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any] else {
                continue
            }
            let payload = (row["payload"] as? [String: Any]) ?? row
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                project = URL(fileURLWithPath: cwd).lastPathComponent
            }
            if let m = payload["model"] as? String { model = m }
            if let ts = row["timestamp"] as? String, let parsed = iso.date(from: ts) {
                timestamp = parsed
            }
            if payload["type"] as? String == "token_count" {
                let info = (payload["info"] as? [String: Any]) ?? payload
                let totals = (info["total_token_usage"] as? [String: Any]) ?? info
                if totals["input_tokens"] != nil || totals["output_tokens"] != nil {
                    last = totals
                }
            }
        }

        guard let last else { return [] }
        let input = number(last["input_tokens"])
        let output = number(last["output_tokens"])
        let cacheRead = number(last["cached_input_tokens"])
        // Unknown model → no dollar guess, just tokens (costUSD 0).
        let cost = pricing.cost(
            model: model,
            inputTokens: input,
            cachedInput: cacheRead,
            output: output
        ) ?? 0
        return [UsageEvent(
            date: timestamp,
            provider: .codex,
            model: model,
            project: project,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: 0,
            costUSD: cost
        )]
    }

    public static func summarize(
        _ events: [UsageEvent],
        since: Date?,
        calendar: Calendar = .current
    ) -> UsageSummary {
        var summary = UsageSummary()
        var byModel: [String: UsageBucket] = [:]
        var byProject: [String: UsageBucket] = [:]
        var byDay: [Date: UsageBucket] = [:]

        for event in events {
            if let since, event.date < since { continue }
            summary.total.add(event)
            summary.byProvider[event.provider, default: UsageBucket()].add(event)
            byModel[shortModel(event.model), default: UsageBucket()].add(event)
            byProject[event.project, default: UsageBucket()].add(event)
            byDay[calendar.startOfDay(for: event.date), default: UsageBucket()].add(event)
        }

        summary.byModel = byModel
            .sorted { $0.value.costUSD != $1.value.costUSD ? $0.value.costUSD > $1.value.costUSD : $0.value.totalTokens > $1.value.totalTokens }
            .map { (model: $0.key, bucket: $0.value) }
        summary.byProject = byProject
            .sorted { $0.value.costUSD != $1.value.costUSD ? $0.value.costUSD > $1.value.costUSD : $0.value.totalTokens > $1.value.totalTokens }
            .map { (project: $0.key, bucket: $0.value) }
        summary.byDay = byDay
            .sorted { $0.key < $1.key }
            .map { (day: $0.key, bucket: $0.value) }
        return summary
    }

    /// "claude-fable-5" from full model ids; keeps unknown ids readable.
    public static func shortModel(_ model: String) -> String {
        model
            .replacingOccurrences(of: "-20[0-9]{6}$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^claude-", with: "", options: .regularExpression)
    }

    private static func number(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }
}

public enum QuotaForecast {
    /// Projects when a window hits 100% at the current burn rate. Returns
    /// nil when there is no meaningful rate or the window resets first.
    public static func exhaustionDate(
        window: QuotaWindow,
        now: Date = Date()
    ) -> Date? {
        guard let resetsAt = window.resetsAt,
              let minutes = window.durationMinutes,
              window.usedFraction > 0.05,
              window.usedFraction < 1 else { return nil }
        let duration = TimeInterval(minutes * 60)
        let windowStart = resetsAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(windowStart)
        guard elapsed > 60 else { return nil }
        let rate = window.usedFraction / elapsed
        let remainingTime = (1 - window.usedFraction) / rate
        let exhaustion = now.addingTimeInterval(remainingTime)
        return exhaustion < resetsAt ? exhaustion : nil
    }
}
