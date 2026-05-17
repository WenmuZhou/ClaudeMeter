import Foundation
import Combine

/// 应用设置。
///
/// 注意：这里**故意不用 `@AppStorage`**。`@AppStorage` 是为 SwiftUI View 设计的
/// `DynamicProperty`，放在 `ObservableObject` 里时修改它不会触发 `objectWillChange`，
/// 导致观察该对象的 View / Combine 订阅收不到通知（设置改了不生效）。
/// 改用 UserDefaults 计算属性 + 手动 `objectWillChange.send()`，保证响应式。
@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let d = UserDefaults.standard

    private init() {
        // bool/int 的默认值是 false/0；非零默认值必须显式注册。
        d.register(defaults: [
            Keys.notificationsEnabled: true,
            Keys.autoRefresh: true,
            Keys.refreshInterval: 5
        ])
    }

    private enum Keys {
        static let notificationsEnabled = "notificationsEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let autoRefresh = "autoRefresh"
        static let refreshInterval = "refreshInterval"
        static let statusBarDisplay = "statusBarDisplay"
        static let tokenFormat = "tokenFormat"
        static let appearance = "appearance"
    }

    var notificationsEnabled: Bool {
        get { d.bool(forKey: Keys.notificationsEnabled) }
        set { objectWillChange.send(); d.set(newValue, forKey: Keys.notificationsEnabled) }
    }

    var launchAtLogin: Bool {
        get { d.bool(forKey: Keys.launchAtLogin) }
        set { objectWillChange.send(); d.set(newValue, forKey: Keys.launchAtLogin) }
    }

    var autoRefresh: Bool {
        get { d.bool(forKey: Keys.autoRefresh) }
        set { objectWillChange.send(); d.set(newValue, forKey: Keys.autoRefresh) }
    }

    /// 刷新间隔（分钟）
    var refreshInterval: Int {
        get { d.integer(forKey: Keys.refreshInterval) }
        set { objectWillChange.send(); d.set(newValue, forKey: Keys.refreshInterval) }
    }

    /// 状态栏显示：0 = 今日，1 = 累计
    var statusBarDisplay: Int {
        get { d.integer(forKey: Keys.statusBarDisplay) }
        set { objectWillChange.send(); d.set(newValue, forKey: Keys.statusBarDisplay) }
    }

    /// 数字格式：0 = K/M，1 = 千/百万
    var tokenFormat: Int {
        get { d.integer(forKey: Keys.tokenFormat) }
        set { objectWillChange.send(); d.set(newValue, forKey: Keys.tokenFormat) }
    }

    /// 外观：0 = 跟随系统，1 = 浅色，2 = 深色
    var appearance: Int {
        get { d.integer(forKey: Keys.appearance) }
        set { objectWillChange.send(); d.set(newValue, forKey: Keys.appearance) }
    }

    // MARK: - Picker options

    var refreshIntervalOptions: [(value: Int, label: String)] {
        [(1, "1分钟"), (5, "5分钟"), (10, "10分钟"), (30, "30分钟"), (60, "1小时")]
    }

    var statusBarDisplayOptions: [(value: Int, label: String)] {
        [(0, "今日"), (1, "累计")]
    }

    var tokenFormatOptions: [(value: Int, label: String)] {
        [(0, "46.6K"), (1, "4.66万")]
    }

    var appearanceOptions: [(value: Int, label: String)] {
        [(0, "系统"), (1, "浅色"), (2, "深色")]
    }
}
