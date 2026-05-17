import SwiftUI
import ServiceManagement
import UserNotifications
import AppKit
import os.log

private let logger = Logging.logger("SettingsView")

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared
    @State private var notificationStatus: String = "检查中..."
    @State private var notificationsDenied: Bool = false
    var onBack: (() -> Void)? = nil
    /// 外观切换「之前」回调 —— 让 PopoverView 抓旧外观快照做 crossfade。
    var onAppearanceWillChange: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header with back button
            ZStack {
                Text("设置")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack {
                    Button {
                        onBack?()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                            Text("返回")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(Theme.Colors.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Theme.Colors.border)
                        )
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(Theme.Colors.bgCard)

            ScrollView {
                VStack(spacing: 16) {
                    // 通用设置
                    SettingsSection(title: "通用", icon: "gearshape.2.fill") {
                        SettingsToggleRow(
                            title: "开机自启",
                            isOn: $settings.launchAtLogin,
                            onChange: { setLaunchAtLogin($0) }
                        )

                        Divider().background(Theme.Colors.divider)

                        SettingsToggleRow(
                            title: "自动刷新",
                            subtitle: settings.autoRefresh ? nil : "关闭后需手动刷新数据",
                            isOn: $settings.autoRefresh
                        )

                        if settings.autoRefresh {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("刷新间隔")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.textTertiary)

                                HStack(spacing: 6) {
                                    ForEach(settings.refreshIntervalOptions, id: \.value) { option in
                                        Button {
                                            settings.refreshInterval = option.value
                                        } label: {
                                            Text(option.label)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(settings.refreshInterval == option.value ? Theme.Colors.onPrimary : Theme.Colors.textTertiary)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 7)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .fill(settings.refreshInterval == option.value ? Theme.Colors.primary : Theme.Colors.bgElevated)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }

                        Divider().background(Theme.Colors.divider)

                        SettingsPickerRow(
                            title: "外观",
                            options: settings.appearanceOptions,
                            selectedValue: $settings.appearance,
                            onWillChange: onAppearanceWillChange
                        )

                        Divider().background(Theme.Colors.divider)

                        SettingsPickerRow(
                            title: "状态栏显示",
                            options: settings.statusBarDisplayOptions,
                            selectedValue: $settings.statusBarDisplay
                        )

                        Divider().background(Theme.Colors.divider)

                        SettingsPickerRow(
                            title: "数字格式",
                            options: settings.tokenFormatOptions,
                            selectedValue: $settings.tokenFormat
                        )
                    }

                    // 通知
                    SettingsSection(title: "通知", icon: "bell.badge.fill") {
                        SettingsToggleRow(
                            title: "启用通知",
                            subtitle: settings.notificationsEnabled ? nil : "关闭后不会收到提醒",
                            isOn: $settings.notificationsEnabled
                        )

                        if settings.notificationsEnabled {
                            Divider().background(Theme.Colors.divider)

                            HStack {
                                Text("通知状态")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.Colors.textPrimary)

                                Spacer()

                                HStack(spacing: 10) {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(notificationsDenied ? Theme.Colors.danger : Theme.Colors.success)
                                            .frame(width: 6, height: 6)
                                        Text(notificationStatus)
                                            .font(.system(size: 10))
                                            .foregroundColor(notificationsDenied ? Theme.Colors.danger : Theme.Colors.success)
                                    }

                                    Button {
                                        requestAndSendNotification()
                                    } label: {
                                        Text("测试")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(Theme.Colors.onPrimary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 5)
                                            .background(Capsule().fill(Theme.Colors.primary))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                            if notificationsDenied {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(Theme.Colors.warning)
                                        .font(.system(size: 11))
                                    Text("通知权限被拒绝，请在系统设置中允许")
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.Colors.textSecondary)
                                    Spacer()
                                    Button {
                                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    } label: {
                                        Text("设置")
                                            .font(.system(size: 10))
                                            .foregroundColor(Theme.Colors.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Theme.Colors.warning.opacity(0.1))
                            }
                        }
                    }

                    // 关于
                    SettingsSection(title: "关于", icon: "info.circle.fill") {
                        HStack {
                            Text("版本")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.Colors.textSecondary)
                            Spacer()
                            Text("1.0.0")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(Theme.Colors.primary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Divider().background(Theme.Colors.divider)

                        HStack {
                            Text("数据源")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.Colors.textSecondary)
                            Spacer()
                            Text("~/.claude/projects")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.Colors.textTertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .frame(maxHeight: .infinity)
        }
        .background(Theme.Colors.bgBase)
        .onAppear {
            checkNotificationStatus()
        }
        // 用户去 macOS 系统设置改完通知权限再回到 app 时，重新检查状态。
        // SettingsView 一直挂在 PopoverView 的 ZStack 里靠 offset 切显隐，
        // .onAppear 一辈子只跑一次，必须靠 NotificationCenter 主动 refresh。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkNotificationStatus()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Failed to set launch at login: \(error.localizedDescription)")
        }
    }

    private func checkNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.notificationStatus = "已授权"
                    self.notificationsDenied = false
                case .denied:
                    self.notificationStatus = "已拒绝"
                    self.notificationsDenied = true
                case .notDetermined:
                    self.notificationStatus = "未设置"
                    self.notificationsDenied = false
                    self.requestNotificationPermission()
                @unknown default:
                    self.notificationStatus = "未知"
                    self.notificationsDenied = false
                }
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async {
                self.checkNotificationStatus()
            }
        }
    }

    private func requestAndSendNotification() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self.sendTestNotification()
            case .notDetermined:
                // Request permission first
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    if granted {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.sendTestNotification()
                            self.checkNotificationStatus()
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.checkNotificationStatus()
                        }
                    }
                }
            case .denied:
                DispatchQueue.main.async {
                    self.notificationStatus = "已拒绝"
                    self.notificationsDenied = true
                }
            default:
                break
            }
        }
    }

    private func sendTestNotification() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                DispatchQueue.main.async {
                    self.checkNotificationStatus()
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "ClaudeMeter"
            content.body = "通知功能正常工作！"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    logger.error("Test notification failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Components

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.Colors.primary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Colors.textSecondary)
            }

            VStack(spacing: 0) {
                content()
            }
            .background(Theme.Colors.bgCard)
            .cornerRadius(12)
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var onChange: ((Bool) -> Void)? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Colors.textPrimary)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Colors.textDisabled)
                }
            }
            Spacer()

            // Custom toggle for better visibility
            Button {
                isOn.toggle()
                onChange?(isOn)
            } label: {
                ZStack {
                    Capsule()
                        .fill(isOn ? Theme.Colors.primary : Theme.Colors.border)
                        .frame(width: 44, height: 24)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 18, height: 18)
                        .offset(x: isOn ? 8 : -8)
                        .animation(.easeInOut(duration: 0.15), value: isOn)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct SettingsPickerRow: View {
    let title: String
    let options: [(value: Int, label: String)]
    @Binding var selectedValue: Int
    /// 值「即将」改变时回调（在写入新值之前）。仅当值真的不同才触发。
    var onWillChange: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.Colors.textPrimary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(options, id: \.value) { option in
                    Button {
                        if selectedValue != option.value {
                            onWillChange?()
                            selectedValue = option.value
                        }
                    } label: {
                        Text(option.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(selectedValue == option.value ? Theme.Colors.onPrimary : Theme.Colors.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(selectedValue == option.value ? Theme.Colors.primary : Theme.Colors.bgElevated)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
