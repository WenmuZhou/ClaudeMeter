import AppKit
import SwiftUI
import Combine
import os.log

private let barLogger = Logging.logger("StatusBarController")

/// 缓存的 day-key formatter（避免每次 updateStatusItemTitle 都新建）。
private let barDayKeyFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
}()

@MainActor
class StatusBarController {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private var refreshTimer: Timer?
    private var settingsCancellable: AnyCancellable?
    private var usageCancellable: AnyCancellable?

    let usageManager = UsageManager()
    private let settings = SettingsManager.shared

    init() {
        barLogger.debug("StatusBarController initializing")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()

        setupPopover()
        setupStatusItem()
        setupSettingsObserver()
        setupUsageObserver()
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

    /// 订阅数据更新：loadData 是异步的，刷新完成后会更新 usageManager.lastUpdate。
    /// 监听它，数据真正落地时才刷新状态栏标题——否则 title 读到的是旧数据，
    /// 直到用户打开 popover 才"看起来更新"。
    private func setupUsageObserver() {
        usageCancellable = usageManager.$lastUpdate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItemTitle()
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

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard settings.autoRefresh else { return }

        let interval = TimeInterval(settings.refreshInterval * 60)
        // 用 Timer.init + RunLoop.add(forMode: .common) 而不是 scheduledTimer：
        // 后者只把 timer 加到 .default 模式，用户开菜单 / 滚 popover 时 run loop
        // 切到 .eventTracking 模式，timer 不触发 → 刷新延迟。.common 覆盖所有 mode。
        //
        // Timer 闭包默认不在 main actor 上，但 StatusBarController 整个标了 @MainActor，
        // 把工作 hop 到 main actor 上执行；先把 weak self 绑到 let，避免内层 Task
        // 直接捕获外层 var 触发 sendable 警告。
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            let weakSelf = self
            Task { @MainActor in
                guard let strongSelf = weakSelf else { return }
                strongSelf.usageManager.loadData(showLoading: false)
                strongSelf.updateStatusItemTitle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
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
        barDayKeyFormatter.string(from: date)
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

    deinit {
        // 把外部资源都收掉。实际上这个 controller 跟 app 同寿命，但 deinit 兜底总是好习惯。
        refreshTimer?.invalidate()
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        NotificationCenter.default.removeObserver(self)
    }
}
