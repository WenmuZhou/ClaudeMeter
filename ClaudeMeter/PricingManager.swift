import Foundation

struct ModelPricing {
    let inputPrice: Double       // per 1M tokens
    let outputPrice: Double      // per 1M tokens
    let cacheCreation: Double    // per 1M tokens
    let cacheRead: Double        // per 1M tokens
}

enum PricingManager {
    /// 默认兜底单价（按 Sonnet）。当模型完全不在表里时返回这个，避免 crash。
    static let defaultPricing = ModelPricing(inputPrice: 3.0, outputPrice: 15.0, cacheCreation: 3.75, cacheRead: 0.30)

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

    /// 模糊匹配定价。先精确查表，再按 family 关键字匹配，最后兜底用 Sonnet。
    /// 全程 `??`，绝不会 crash。
    static func getPricing(for model: String) -> ModelPricing {
        if let pricing = pricingTiers[model] {
            return pricing
        }

        let lower = model.lowercased()
        if lower.contains("opus") {
            return pricingTiers["claude-opus-4-6"] ?? defaultPricing
        } else if lower.contains("sonnet") {
            return pricingTiers["claude-sonnet-4-6"] ?? defaultPricing
        } else if lower.contains("haiku") {
            return pricingTiers["claude-haiku-4-5-20251001"] ?? defaultPricing
        }

        return defaultPricing
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
