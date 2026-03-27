import AppKit
import SwiftUI
import Combine
import os.log

private let barLogger = Logger(subsystem: "com.personal.ClaudeMeter", category: "StatusBarController")

@MainActor
class StatusBarController: ObservableObject {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private var refreshTimer: Timer?
    private var settingsCancellable: AnyCancellable?

    let usageManager = UsageManager()
    private let settings = SettingsManager.shared

    init() {
        barLogger.debug("StatusBarController initializing")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()

        setupPopover()
        setupStatusItem()
        setupSettingsObserver()
        startRefreshTimer()

        barLogger.debug("Starting initial refresh")
        Task {
            usageManager.loadData(showLoading: false)
            updateStatusItemTitle()
            barLogger.debug("Initial refresh complete")
        }
    }

    private func setupSettingsObserver() {
        // Observe settings changes
        settingsCancellable = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.applySettings()
            }
        }
    }

    private func applySettings() {
        updateStatusItemTitle()
        startRefreshTimer()
    }

    private func setupPopover() {
        popover.contentSize = NSSize(width: 360, height: 540)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                usageManager: usageManager,
                onOpenSettings: { [weak self] in
                    self?.openSettings()
                },
                onQuit: {
                    NSApplication.shared.terminate(nil)
                }
            )
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popoverWillClose),
            name: NSPopover.willCloseNotification,
            object: popover
        )
    }

    @objc private func popoverWillClose(_ notification: Notification) {
        removeClickMonitor()
    }

    private func setupStatusItem() {
        if let button = statusItem.button {
            // Set status bar icon - flame icon matching main UI
            if let image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "ClaudeMeter") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeading
            }
            button.title = "--"
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "刷新", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 ClaudeMeter", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusMenu = menu
    }

    private var statusMenu: NSMenu?

    @objc func refreshFromMenu() {
        usageManager.loadData(showLoading: false)
        updateStatusItemTitle()
    }

    @objc func openSettingsFromMenu() {
        openSettings()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard settings.autoRefresh else { return }

        let interval = TimeInterval(settings.refreshInterval * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.usageManager.loadData(showLoading: false)
            self.updateStatusItemTitle()
        }
    }

    func updateStatusItemTitle() {
        guard let button = statusItem.button else { return }

        let tokens: Int
        let todayStr = formatDayKey(Date())
        let todayTokens = usageManager.dailyData.first(where: { $0.date == todayStr })?.tokens ?? 0
        let totalTokens = usageManager.monthlyData.reduce(0) { $0 + $1.details.total }

        // Use setting to determine what to show
        if settings.statusBarDisplay == 0 {
            tokens = todayTokens
        } else {
            tokens = totalTokens
        }

        let title = formatTokenCount(tokens)

        // Create attributed title with icon - reduced spacing
        let fullTitle = " \(title)"
        button.attributedTitle = NSAttributedString(
            string: fullTitle,
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .kern: NSNumber(value: 0)
            ]
        )
    }

    private func formatTokenCount(_ value: Int) -> String {
        if settings.tokenFormat == 1 {
            // Chinese format: 万
            if value >= 10_000_000 {
                return String(format: "%.1f千万", Double(value) / 10_000_000)
            } else if value >= 10_000 {
                return String(format: "%.1f万", Double(value) / 10_000)
            }
            return String(value)
        } else {
            // English format: K/M
            if value >= 1_000_000 {
                return String(format: "%.1fM", Double(value) / 1_000_000)
            } else if value >= 1_000 {
                return String(format: "%.1fK", Double(value) / 1_000)
            }
            return String(value)
        }
    }

    private func formatDayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            if let button = statusItem.button, let menu = statusMenu {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
            }
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            usageManager.loadData(showLoading: false)
            updateStatusItemTitle()

            addClickMonitor()
        }
    }

    private var clickMonitor: Any?

    private func addClickMonitor() {
        removeClickMonitor()

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
            self?.removeClickMonitor()
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    func openSettings() {
        popover.performClose(nil)
        removeClickMonitor()

        NSApp.activate(ignoringOtherApps: true)

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "设置"
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(hex: "0f0f1a")
        window.isOpaque = false
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}
