import SwiftUI

/// 全 app 的设计 token。所有颜色 / 字号 / 圆角 / 间距走这里。
/// 颜色按 light / dark 双套定义，跟 SwiftUI 当前 colorScheme 自动切换。
enum Theme {

    // MARK: - Colors

    enum Colors {
        // MARK: Surfaces (双模式)
        // 深色：原来的 #0f0f1a / #1a1a2e；浅色：高亮中性灰白
        static let bgBase = Color(
            light: Color(hex: "f5f5f7"),    // 略带蓝灰的浅底，跟 macOS 系统 BG 调和
            dark:  Color(hex: "0f0f1a")
        )
        static let bgCard = Color(
            light: Color(hex: "ffffff"),
            dark:  Color(hex: "1a1a2e")
        )
        static let bgElevated = Color(
            light: Color.black.opacity(0.04),
            dark:  Color.white.opacity(0.05)
        )
        /// 选中态背景（tab、view mode toggle 等）
        static let bgSelected = Color(
            light: Color.black.opacity(0.07),
            dark:  Color.white.opacity(0.10)
        )
        /// 永远是白色 — 用于 primary CTA（紫色按钮、彩色 capsule）上的文字。
        static let onPrimary = Color.white
        static let border = Color(
            light: Color.black.opacity(0.08),
            dark:  Color.white.opacity(0.08)
        )
        static let divider = Color(
            light: Color.black.opacity(0.08),
            dark:  Color.white.opacity(0.10)
        )

        // MARK: Text (双模式分级；浅色用纯 black scale，深色用 white scale)
        // 在 bgCard 上对照 WCAG AA：
        // - light 上 black.opacity(0.65) ≈ 5.0:1 通过
        // - dark  上 white.opacity(0.55) ≈ 5.2:1 通过
        static let textPrimary = Color(
            light: Color.black.opacity(0.92),
            dark:  Color.white.opacity(1.0)
        )
        static let textSecondary = Color(
            light: Color.black.opacity(0.65),
            dark:  Color.white.opacity(0.70)
        )
        static let textTertiary = Color(
            light: Color.black.opacity(0.50),
            dark:  Color.white.opacity(0.55)
        )
        static let textDisabled = Color(
            light: Color.black.opacity(0.30),
            dark:  Color.white.opacity(0.35)
        )

        // MARK: Brand (品牌色保留单套：渐变大字/按钮场景对比度足够)
        static let primary = Color(hex: "667eea")
        static let primaryDeep = Color(hex: "764ba2")
        static let primaryGradient = LinearGradient(
            colors: [primary, primaryDeep],
            startPoint: .leading, endPoint: .trailing
        )

        // Logo
        static let logoStart = Color(hex: "FF6B35")
        static let logoEnd = Color(hex: "F7931E")

        // MARK: Semantic accents (双套)
        // 这些色经常直接当文字用（token 数字、模型名）。深色变体是原来的霓虹亮色，
        // 在 #1a1a2e 上好看；浅色变体换成深一档（Tailwind 600/700 级），
        // 保证在白卡上对比度 ≥ WCAG AA。

        // Token breakdown
        static let inputColor = Color(
            light: Color(hex: "2563eb"), dark: Color(hex: "4facfe")
        )
        static let outputColor = Color(
            light: Color(hex: "0e7490"), dark: Color(hex: "00f2fe")
        )
        static let cacheColor = Color(
            light: Color(hex: "db2777"), dark: Color(hex: "fa709a")
        )

        // Status
        static let success = Color(
            light: Color(hex: "15803d"), dark: Color(hex: "22c55e")
        )
        static let warning = Color(
            light: Color(hex: "b45309"), dark: Color(hex: "f59e0b")
        )
        static let danger = Color(
            light: Color(hex: "dc2626"), dark: Color(hex: "ef4444")
        )

        // Trend (中性)
        static let trendUp = inputColor       // 跟随 input 的自适应蓝
        static let trendDown = textTertiary   // 自适应灰

        // Model identity
        static let modelOpus = Color(
            light: Color(hex: "a21caf"), dark: Color(hex: "E879F9")
        )
        static let modelSonnet = primary
        static let modelHaiku = Color(
            light: Color(hex: "047857"), dark: Color(hex: "34D399")
        )
        static let modelQwen = Color(
            light: Color(hex: "b45309"), dark: Color(hex: "F59E0B")
        )
        static let modelPitaya = Color(
            light: Color(hex: "be123c"), dark: Color(hex: "FB7185")
        )
        static let modelOther = Color(
            light: Color(hex: "4b5563"), dark: Color(hex: "6B7280")
        )
    }

    // MARK: - Text opacity (legacy; 新代码请直接用 Theme.Colors.textXxx)
    /// 仅作历史兼容保留，避免一次性大改。新代码统一用 textPrimary/Secondary/Tertiary。
    enum TextOpacity {
        static let primary: Double = 1.0
        static let secondary: Double = 0.7
        static let tertiary: Double = 0.55
        static let disabled: Double = 0.35
    }

    // MARK: - Typography
    enum Typography {
        // Stat numbers
        static let displayHuge = Font.system(size: 42, weight: .bold, design: .rounded)
        static let statBody = Font.system(size: 14, weight: .semibold, design: .rounded)
        static let statSmall = Font.system(size: 13, weight: .bold, design: .rounded)

        // UI text
        static let title = Font.system(size: 13, weight: .semibold)
        static let bodyMedium = Font.system(size: 12, weight: .medium)
        static let body = Font.system(size: 12)

        static let label = Font.system(size: 11, weight: .medium)
        static let caption = Font.system(size: 10)
        static let captionMedium = Font.system(size: 10, weight: .medium)
    }

    // MARK: - Corner radii
    enum Radius {
        static let xs: CGFloat = 5
        static let sm: CGFloat = 8
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 16
    }

    // MARK: - Spacing scale
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: - Animations
    enum Motion {
        static let quick = Animation.easeInOut(duration: 0.15)
        static let standard = Animation.easeInOut(duration: 0.25)
        static let chartUpdate = Animation.easeOut(duration: 0.4)
        static let numericRoll = Animation.easeOut(duration: 0.5)
    }
}
