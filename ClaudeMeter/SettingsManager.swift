import Foundation
import SwiftUI
import Combine

@MainActor
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @AppStorage("notificationsEnabled") var notificationsEnabled: Bool = true
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("autoRefresh") var autoRefresh: Bool = true
    @AppStorage("refreshInterval") var refreshInterval: Int = 5  // minutes
    @AppStorage("statusBarDisplay") var statusBarDisplay: Int = 0  // 0 = today, 1 = total
    @AppStorage("tokenFormat") var tokenFormat: Int = 0  // 0 = K/M, 1 = 千/百万

    var refreshIntervalOptions: [(value: Int, label: String)] {
        [
            (1, "1分钟"),
            (5, "5分钟"),
            (10, "10分钟"),
            (30, "30分钟"),
            (60, "1小时")
        ]
    }

    var statusBarDisplayOptions: [(value: Int, label: String)] {
        [
            (0, "今日"),
            (1, "累计")
        ]
    }

    var tokenFormatOptions: [(value: Int, label: String)] {
        [
            (0, "46.6K"),
            (1, "4.66万")
        ]
    }

    private init() {}
}
