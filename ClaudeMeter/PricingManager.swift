import Foundation

struct ModelPricing {
    let inputPrice: Double       // per 1M tokens
    let outputPrice: Double      // per 1M tokens
    let cacheCreation: Double    // per 1M tokens
    let cacheRead: Double        // per 1M tokens
}

enum PricingManager {
    static let pricingTiers: [String: ModelPricing] = [
        // Claude 4.5/4.6 models
        "claude-opus-4-6": ModelPricing(inputPrice: 15.0, outputPrice: 75.0, cacheCreation: 18.75, cacheRead: 1.50),
        "claude-opus-4-5": ModelPricing(inputPrice: 15.0, outputPrice: 75.0, cacheCreation: 18.75, cacheRead: 1.50),
        "claude-sonnet-4-6": ModelPricing(inputPrice: 3.0, outputPrice: 15.0, cacheCreation: 3.75, cacheRead: 0.30),
        "claude-sonnet-4-5": ModelPricing(inputPrice: 3.0, outputPrice: 15.0, cacheCreation: 3.75, cacheRead: 0.30),
        "claude-haiku-4-5-20251001": ModelPricing(inputPrice: 0.80, outputPrice: 4.0, cacheCreation: 1.0, cacheRead: 0.08),

        // Claude 4 models
        "claude-sonnet-4-20250514": ModelPricing(inputPrice: 3.0, outputPrice: 15.0, cacheCreation: 3.75, cacheRead: 0.30),

        // Claude 3.5 models
        "claude-3-5-sonnet-20241022": ModelPricing(inputPrice: 3.0, outputPrice: 15.0, cacheCreation: 3.75, cacheRead: 0.30),
        "claude-3-5-haiku-20241022": ModelPricing(inputPrice: 0.80, outputPrice: 4.0, cacheCreation: 1.0, cacheRead: 0.08),

        // Claude 3 models
        "claude-3-opus-20240229": ModelPricing(inputPrice: 15.0, outputPrice: 75.0, cacheCreation: 18.75, cacheRead: 1.50),
        "claude-3-sonnet-20240229": ModelPricing(inputPrice: 3.0, outputPrice: 15.0, cacheCreation: 3.75, cacheRead: 0.30),
        "claude-3-haiku-20240307": ModelPricing(inputPrice: 0.25, outputPrice: 1.25, cacheCreation: 0.30, cacheRead: 0.03),
    ]

    static func getPricing(for model: String) -> ModelPricing {
        // Try exact match first
        if let pricing = pricingTiers[model] {
            return pricing
        }

        // Try partial match (e.g., "opus" in model name)
        let lowercasedModel = model.lowercased()
        if lowercasedModel.contains("opus") {
            return pricingTiers["claude-opus-4-6"]!
        } else if lowercasedModel.contains("sonnet") {
            return pricingTiers["claude-sonnet-4-6"]!
        } else if lowercasedModel.contains("haiku") {
            return pricingTiers["claude-haiku-4-5-20251001"]!
        }

        // Default to Sonnet pricing if unknown
        return pricingTiers["claude-sonnet-4-6"]!
    }

    static func calculateCost(input: Int, cacheCreation: Int, cacheRead: Int, output: Int, model: String) -> Double {
        let pricing = getPricing(for: model)

        let inputCost = Double(input) * (pricing.inputPrice / 1_000_000)
        let cacheCreationCost = Double(cacheCreation) * (pricing.cacheCreation / 1_000_000)
        let cacheReadCost = Double(cacheRead) * (pricing.cacheRead / 1_000_000)
        let outputCost = Double(output) * (pricing.outputPrice / 1_000_000)

        return inputCost + cacheCreationCost + cacheReadCost + outputCost
    }
}
