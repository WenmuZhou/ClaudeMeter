import SwiftUI
import AppKit

/// 用 hex 字符串构造 Color。支持 RGB(3) / RGB(6) / ARGB(8)。
/// 所有 UI 颜色统一从这里来，避免把扩展埋在 view 文件里。
extension Color {
    /// 自适应颜色：跟随系统/SwiftUI 当前 colorScheme 在 light/dark 间切换。
    /// 实现走 NSColor 的 dynamicProvider，比 @Environment(colorScheme) 更彻底——
    /// 即使在不依赖 view 重绘的地方（如 NSHostingController 嵌套）也能正确响应。
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
            case .darkAqua:
                return NSColor(dark)
            default:
                return NSColor(light)
            }
        })
    }

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
