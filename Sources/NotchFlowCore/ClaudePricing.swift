import Foundation

public struct ClaudeRates: Codable, Equatable, Sendable {
    public let input: Double
    public let cache5m: Double
    public let cache1h: Double
    public let cacheRead: Double
    public let output: Double

    public init(input: Double, cache5m: Double, cache1h: Double, cacheRead: Double, output: Double) {
        self.input = input
        self.cache5m = cache5m
        self.cache1h = cache1h
        self.cacheRead = cacheRead
        self.output = output
    }
}

public struct PricingRule: Codable, Equatable, Sendable {
    public let contains: [String]
    public let notBefore: Date?
    public let notAfter: Date?
    public let rates: ClaudeRates

    public init(
        contains: [String],
        notBefore: Date? = nil,
        notAfter: Date? = nil,
        rates: ClaudeRates
    ) {
        self.contains = contains
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.rates = rates
    }
}

/// API-equivalent list prices per million tokens. Rules are evaluated in
/// order; a user-provided pricing.json in Application Support overrides the
/// built-in table so price changes never require shipping a new build.
public struct ClaudePricing: Sendable {
    public let rules: [PricingRule]

    public static let builtin: ClaudePricing = {
        let promoEnd = ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")
        return ClaudePricing(rules: [
            PricingRule(
                contains: ["fable-5", "mythos-5"],
                rates: ClaudeRates(input: 10, cache5m: 12.5, cache1h: 20, cacheRead: 1, output: 50)
            ),
            PricingRule(
                contains: ["opus-4-8", "opus-4-7", "opus-4-6", "opus-4-5"],
                rates: ClaudeRates(input: 5, cache5m: 6.25, cache1h: 10, cacheRead: 0.5, output: 25)
            ),
            PricingRule(
                contains: ["opus"],
                rates: ClaudeRates(input: 15, cache5m: 18.75, cache1h: 30, cacheRead: 1.5, output: 75)
            ),
            PricingRule(
                contains: ["sonnet-5"],
                notAfter: promoEnd,
                rates: ClaudeRates(input: 2, cache5m: 2.5, cache1h: 4, cacheRead: 0.2, output: 10)
            ),
            PricingRule(
                contains: ["sonnet-5"],
                rates: ClaudeRates(input: 3, cache5m: 3.75, cache1h: 6, cacheRead: 0.3, output: 15)
            ),
            PricingRule(
                contains: ["sonnet"],
                rates: ClaudeRates(input: 3, cache5m: 3.75, cache1h: 6, cacheRead: 0.3, output: 15)
            ),
            PricingRule(
                contains: ["haiku-4-5"],
                rates: ClaudeRates(input: 1, cache5m: 1.25, cache1h: 2, cacheRead: 0.1, output: 5)
            ),
            PricingRule(
                contains: ["haiku-3-5"],
                rates: ClaudeRates(input: 0.8, cache5m: 1, cache1h: 1.6, cacheRead: 0.08, output: 4)
            ),
            PricingRule(
                contains: ["haiku"],
                rates: ClaudeRates(input: 0.25, cache5m: 0.3, cache1h: 0.5, cacheRead: 0.03, output: 1.25)
            )
        ])
    }()

    public init(rules: [PricingRule]) {
        self.rules = rules
    }

    /// Override rules win, but the builtin table stays as fallback: a
    /// partial pricing.json must not silently zero-out every other model.
    public static func load(overridePath: String = BridgeLocation.pricingOverridePath) -> ClaudePricing {
        guard let data = FileManager.default.contents(atPath: overridePath) else { return .builtin }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let rules = try? decoder.decode([PricingRule].self, from: data),
              !rules.isEmpty else { return .builtin }
        return ClaudePricing(rules: rules + builtin.rules)
    }

    public func rates(for rawModel: String, now: Date = Date()) -> ClaudeRates? {
        let model = rawModel.lowercased()
        return rules.first { rule in
            if let notBefore = rule.notBefore, now < notBefore { return false }
            if let notAfter = rule.notAfter, now >= notAfter { return false }
            return rule.contains.contains { model.contains($0) }
        }?.rates
    }
}

public enum TranscriptCost {
    private static let maximumTranscriptBytes = 64 * 1_024 * 1_024

    /// Reads a Claude Code transcript and sums the API-equivalent cost of its
    /// assistant messages, deduplicated by message id. Only paths inside the
    /// allowed root are read; nothing is transmitted anywhere.
    public static func claudeEquivalentCost(
        transcriptPath: String?,
        allowedRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true),
        pricing: ClaudePricing = .load()
    ) -> Double? {
        claudeTranscriptSummary(
            transcriptPath: transcriptPath,
            allowedRoot: allowedRoot,
            pricing: pricing
        )?.costUSD
    }

    public static func claudeTranscriptSummary(
        transcriptPath: String?,
        allowedRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true),
        pricing: ClaudePricing = .load()
    ) -> (costUSD: Double, lastModel: String?, lastAssistantText: String?, unpricedModels: [String])? {
        guard let transcriptPath, transcriptPath.hasSuffix(".jsonl") else { return nil }
        let url = URL(fileURLWithPath: transcriptPath).standardizedFileURL
        let rootPath = allowedRoot.standardizedFileURL.path + "/"
        guard url.path.hasPrefix(rootPath),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumTranscriptBytes),
              !data.isEmpty else { return nil }
        let breakdown = claudeCostBreakdown(transcript: data, pricing: pricing)
        guard let cost = breakdown.costUSD else { return nil }
        let tail = lastAssistantDetails(in: data)
        return (cost, tail.model, tail.text, breakdown.unpricedModels)
    }

    /// What the agent actually said last: this is what the notch shows when
    /// a turn finishes, so the island mirrors the terminal's conversation
    /// instead of surfacing a stale tool command.
    private static func lastAssistantDetails(in transcript: Data) -> (model: String?, text: String?) {
        var model: String?
        var text: String?
        for rawLine in transcript.split(separator: 0x0A).reversed() {
            guard let row = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                  row["type"] as? String == "assistant",
                  let message = row["message"] as? [String: Any] else { continue }
            if model == nil {
                model = message["model"] as? String
            }
            if text == nil, let content = message["content"] as? [[String: Any]] {
                let fragment = content
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !fragment.isEmpty { text = fragment }
            }
            if model != nil, text != nil { break }
        }
        return (model, text)
    }

    public static func claudeEquivalentCost(
        transcript: Data,
        pricing: ClaudePricing = .builtin,
        now: Date = Date()
    ) -> Double? {
        claudeCostBreakdown(transcript: transcript, pricing: pricing, now: now).costUSD
    }

    /// The honest version: alongside the total, names every model the
    /// pricing table could not price. Costs with unpriced models are a
    /// floor, and callers must say so instead of showing a confident total.
    public static func claudeCostBreakdown(
        transcript: Data,
        pricing: ClaudePricing = .builtin,
        now: Date = Date()
    ) -> (costUSD: Double?, unpricedModels: [String]) {
        var costsByMessage: [String: Double] = [:]
        var unpriced: Set<String> = []
        for rawLine in transcript.split(separator: 0x0A) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                  row["type"] as? String == "assistant",
                  let message = row["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  let usage = message["usage"] as? [String: Any] else { continue }
            guard let rates = pricing.rates(for: model, now: now) else {
                if model != "<synthetic>" { unpriced.insert(model) }
                continue
            }
            let identity = (message["id"] as? String) ?? (row["uuid"] as? String) ?? UUID().uuidString
            let input = doubleValue(usage["input_tokens"]) ?? 0
            let output = doubleValue(usage["output_tokens"]) ?? 0
            let cacheRead = doubleValue(usage["cache_read_input_tokens"]) ?? 0
            let cacheTotal = doubleValue(usage["cache_creation_input_tokens"]) ?? 0
            let cacheBreakdown = usage["cache_creation"] as? [String: Any] ?? [:]
            let cache1h = doubleValue(cacheBreakdown["ephemeral_1h_input_tokens"]) ?? 0
            let cache5m = doubleValue(cacheBreakdown["ephemeral_5m_input_tokens"])
                ?? max(0, cacheTotal - cache1h)
            let webSearches = ((usage["server_tool_use"] as? [String: Any])
                .flatMap { doubleValue($0["web_search_requests"]) }) ?? 0
            let geoMultiplier = usage["inference_geo"] as? String == "us" ? 1.1 : 1

            var cost = geoMultiplier * (
                input * rates.input + output * rates.output +
                cacheRead * rates.cacheRead + cache1h * rates.cache1h + cache5m * rates.cache5m
            ) / 1_000_000
            cost += webSearches * 0.01
            costsByMessage[identity] = cost
        }
        let total = costsByMessage.isEmpty ? nil : costsByMessage.values.reduce(0, +)
        return (total, unpriced.sorted())
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
