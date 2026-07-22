import Foundation

public struct OpenAIRates: Codable, Equatable, Sendable {
    public let input: Double        // USD per 1M tokens
    public let cachedInput: Double
    public let output: Double

    public init(input: Double, cachedInput: Double, output: Double) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
    }
}

public struct OpenAIPricingRule: Codable, Equatable, Sendable {
    public let contains: [String]
    public let rates: OpenAIRates

    public init(contains: [String], rates: OpenAIRates) {
        self.contains = contains
        self.rates = rates
    }
}

/// API-equivalent list prices for the models Codex runs. This is an estimate
/// on purpose: Codex reports internal variant names (gpt-5.6-terra/-sol) that
/// are not public API SKUs, so the base GPT-5 list price is applied and the
/// whole table is overridable via openai-pricing.json. A model the table
/// cannot match stays at zero cost and is reported as tokens, never a guess.
public struct OpenAIPricing: Sendable {
    public let rules: [OpenAIPricingRule]

    public static let builtin = OpenAIPricing(rules: [
        OpenAIPricingRule(
            contains: ["gpt-5-nano", "5-nano"],
            rates: OpenAIRates(input: 0.05, cachedInput: 0.005, output: 0.4)
        ),
        OpenAIPricingRule(
            contains: ["gpt-5-mini", "5-mini"],
            rates: OpenAIRates(input: 0.25, cachedInput: 0.025, output: 2)
        ),
        // The flagship GPT-5 line, including the gpt-5.x variants Codex uses.
        OpenAIPricingRule(
            contains: ["gpt-5", "codex"],
            rates: OpenAIRates(input: 1.25, cachedInput: 0.125, output: 10)
        )
    ])

    public init(rules: [OpenAIPricingRule]) {
        self.rules = rules
    }

    /// Override rules win, but the builtin table stays as a fallback so a
    /// partial override never silently zeroes out every other model.
    public static func load(overridePath: String = BridgeLocation.openAIPricingOverridePath) -> OpenAIPricing {
        guard let data = FileManager.default.contents(atPath: overridePath),
              let rules = try? JSONDecoder().decode([OpenAIPricingRule].self, from: data),
              !rules.isEmpty else { return .builtin }
        return OpenAIPricing(rules: rules + builtin.rules)
    }

    public func rates(for rawModel: String) -> OpenAIRates? {
        let model = rawModel.lowercased()
        return rules.first { rule in
            rule.contains.contains { model.contains($0) }
        }?.rates
    }

    /// `inputTokens` is the total prompt size; `cachedInput` is the cached
    /// slice of it billed cheaper, so only the remainder pays full price.
    public func cost(
        model: String,
        inputTokens: Double,
        cachedInput: Double,
        output: Double
    ) -> Double? {
        guard let rates = rates(for: model) else { return nil }
        let billableInput = max(0, inputTokens - cachedInput)
        return (billableInput * rates.input
            + cachedInput * rates.cachedInput
            + output * rates.output) / 1_000_000
    }
}
