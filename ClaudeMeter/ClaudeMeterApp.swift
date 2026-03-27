import SwiftUI
import UserNotifications
import os.log

private let appLogger = Logger(subsystem: "com.personal.ClaudeMeter", category: "ClaudeMeterApp")

@main
struct ClaudeMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        appLogger.debug("ClaudeMeter app starting")
    }

    var body: some Scene {
        Settings {
            SettingsView()
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

    func applicationShouldOpenUntitledWindow(_ sender: NSApplication) -> Bool {
        false
    }

    // Show notification even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
