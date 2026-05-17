import SwiftUI
import UserNotifications
import os.log

private let appLogger = Logging.logger("ClaudeMeterApp")

@main
struct ClaudeMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        appLogger.debug("ClaudeMeter app starting")
    }

    var body: some Scene {
        // Settings scene 不会自动创建可见窗口，配合 Info.plist 的 LSUIElement=YES
        // 实现纯菜单栏 app —— 既不显示 Dock 图标，启动时也没有白窗闪烁。
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLogger.debug("Application did finish launching")

        // Set up notification center delegate
        UNUserNotificationCenter.current().delegate = self

        statusBarController = StatusBarController()
    }

    // Show notification even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
