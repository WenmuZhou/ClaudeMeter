import SwiftUI
import AppKit

// MARK: - Cached Date Formatters
// DateFormatter 构造开销大，绝不能 per-call 新建。集中缓存在模块级。

private let fmtTime: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
}()
private let fmtDayKey: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
}()
private let fmtChartLabel: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "M/d"; return f
}()
private let fmtMonthKey: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f
}()
private let fmtMonthLabel: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "M月"; return f
}()
private let fmtTooltipMonth: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月"; return f
}()
private let fmtTooltipWeek: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy/M/d 起"; return f
}()
private let fmtTooltipDay: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy/M/d EEE"; return f
}()

// MARK: - Popover View

struct PopoverView: View {
    @ObservedObject var usageManager: UsageManager
    @ObservedObject private var settings = SettingsManager.shared
    var onQuit: () -> Void

    @State private var selectedTab: Int = 0
    @State private var viewMode: Int = 0  // 0 = today, 1 = history
    /// 历史折线图周期：0 = 月（默认）、1 = 周、2 = 日
    @State private var historyPeriod: Int = 0
    @State private var showSettings: Bool = false
    // 图表交互态
    @State private var hoveredBarIndex: Int? = nil
    @State private var hoveredLineIndex: Int? = nil

    // 日夜模式切换的交叉淡出：切换前把旧外观渲染成快照盖在最上层，
    // 底下内容瞬切到新外观，再把快照淡出 → 视觉上是 crossfade。
    @State private var transitionSnapshot: Image?
    @State private var snapshotOpacity: Double = 1
    /// 防止用户快速连切外观时，旧的清理任务提前清掉新快照。
    @State private var transitionToken: Int = 0
    @Environment(\.colorScheme) private var currentScheme
    @Environment(\.displayScale) private var displayScale

    /// 把 settings.appearance 映射为 SwiftUI 的 ColorScheme。
    /// 0 = 跟随系统（返回 nil，preferredColorScheme(nil) 表示不强制），
    /// 1 = 浅色，2 = 深色。
    private var preferredScheme: ColorScheme? {
        switch settings.appearance {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    // MARK: - Computed Properties

    private var yesterdayData: Int {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let yesterdayStr = formatDateKey(yesterday)
        if let entry = usageManager.dailyData.first(where: { $0.date == yesterdayStr }) {
            return entry.tokens
        }
        return 0
    }

    /// 图表数据缓存。由 chartDataTrigger 驱动重算（见 body 的 .onChange），
    /// 避免 hover 等高频重绘时反复跑聚合 + 建 formatter。
    @State private var chartData: [(date: Date, tokens: Int, label: String)] = []

    /// chartData 的重算触发键：viewMode / historyPeriod / 数据更新 任一变化时重算。
    private var chartDataTrigger: String {
        "\(viewMode)|\(historyPeriod)|\(usageManager.lastUpdate.timeIntervalSince1970)"
    }

    private func computeChartData() -> [(date: Date, tokens: Int, label: String)] {
        if viewMode == 0 {
            // Today mode: last 7 days
            let days = 7
            let calendar = Calendar.current
            let today = Date()

            var result: [(date: Date, tokens: Int, label: String)] = []
            for i in (0..<days).reversed() {
                if let date = calendar.date(byAdding: .day, value: -i, to: today) {
                    let dateStr = formatDateKey(date)
                    let tokens = usageManager.dailyData.first(where: { $0.date == dateStr })?.tokens ?? 0
                    let label = formatChartLabel(date)
                    result.append((date: date, tokens: tokens, label: label))
                }
            }
            return result
        } else {
            // History mode: aggregate all-time data by selected period
            let allDaily = usageManager.getDailyData(forMonth: nil)
            switch historyPeriod {
            case 0: return aggregateByMonth(allDaily)
            case 1: return aggregateByWeek(allDaily)
            default: return aggregateByDay(allDaily)
            }
        }
    }

    /// 按月聚合：每月一个数据点。
    private func aggregateByMonth(_ daily: [(date: String, tokens: Int)]) -> [(date: Date, tokens: Int, label: String)] {
        var monthMap: [String: Int] = [:]
        for entry in daily {
            let key = String(entry.date.prefix(7))  // "2026-03"
            monthMap[key, default: 0] += entry.tokens
        }
        return monthMap.compactMap { (key, tokens) -> (date: Date, tokens: Int, label: String)? in
            guard let date = fmtMonthKey.date(from: key) else { return nil }
            return (date: date, tokens: tokens, label: fmtMonthLabel.string(from: date))
        }.sorted { $0.date < $1.date }
    }

    /// 按周聚合（自然周，周一作为周起始）。
    private func aggregateByWeek(_ daily: [(date: String, tokens: Int)]) -> [(date: Date, tokens: Int, label: String)] {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2  // 周一
        var weekMap: [Date: Int] = [:]
        for entry in daily {
            guard let date = parseDate(entry.date) else { continue }
            let weekStart = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            weekMap[weekStart, default: 0] += entry.tokens
        }
        return weekMap.map { (date, tokens) in
            (date: date, tokens: tokens, label: fmtChartLabel.string(from: date))
        }.sorted { $0.date < $1.date }
    }

    /// 按日聚合（直接 1:1 映射）。
    private func aggregateByDay(_ daily: [(date: String, tokens: Int)]) -> [(date: Date, tokens: Int, label: String)] {
        return daily.compactMap { (dateStr, tokens) -> (date: Date, tokens: Int, label: String)? in
            guard let date = parseDate(dateStr) else { return nil }
            return (date: date, tokens: tokens, label: formatChartLabel(date))
        }.sorted { $0.date < $1.date }
    }

    private var filteredBreakdown: TokenBreakdown {
        if viewMode == 0 {
            return usageManager.todayBreakdown
        } else {
            return usageManager.getBreakdown(forMonth: nil)  // 历史模式总是看累计
        }
    }

    typealias TokenBreakdown = UsageManager.TokenBreakdown

    // MARK: - Body

    /// 首次加载（无任何数据）时把整个内容区交给 SwiftUI 的 .placeholder 重绘成 skeleton。
    /// 已有历史数据但在刷新时不触发，避免数据闪现。
    private var isInitialLoading: Bool {
        usageManager.isLoading && filteredBreakdown.total == 0
    }

    /// 主内容（与外观无关；colorScheme 由 body 的 preferredColorScheme 或快照渲染时显式注入决定）。
    private var mainContent: some View {
        ZStack {
            // Main page
            VStack(spacing: 0) {
                headerView

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        mainStatsCard
                        chartSection
                        tabContentSection
                    }
                    .padding(16)
                    .redacted(reason: isInitialLoading ? .placeholder : [])
                }

                footerView
            }
            .offset(x: showSettings ? -360 : 0)

            // Settings page
            SettingsView(
                onBack: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showSettings = false
                    }
                },
                onAppearanceWillChange: { snapshotForTransition() }
            )
            .frame(width: 360, height: 540)
            .offset(x: showSettings ? 0 : 360)
        }
        .frame(width: 360, height: 540)
        // 整个 popover 统一用 bgCard（跟"今日使用"等卡片同色），让中间区与卡片融为一体。
        .background(Theme.Colors.bgCard)
        .clipped()
    }

    var body: some View {
        mainContent
            // 旧外观快照盖在最上层，淡出时露出底下的新外观 → crossfade
            .overlay {
                if let snap = transitionSnapshot {
                    snap
                        .resizable()
                        .frame(width: 360, height: 540)
                        .opacity(snapshotOpacity)
                        .allowsHitTesting(false)
                }
            }
            // 应用用户的外观偏好；nil 表示跟随系统。
            .preferredColorScheme(preferredScheme)
            // 只在 viewMode / 周期 / 数据更新时重算图表数据，避免 hover 高频重绘反复聚合。
            .onChange(of: chartDataTrigger, initial: true) { _, _ in
                chartData = computeChartData()
            }
    }

    /// 在切换外观「之前」调用：把当前（旧）外观渲染成静态快照，盖在最上层后淡出。
    @MainActor
    private func snapshotForTransition() {
        let renderer = ImageRenderer(
            content: mainContent.environment(\.colorScheme, currentScheme)
        )
        renderer.scale = displayScale

        // 关键：ImageRenderer 解析 Color(light:dark:) 背后的动态 NSColor 时，依据的是
        // 渲染那一刻生效的 NSAppearance，而不是注入的 SwiftUI colorScheme。若不强制，
        // 快照颜色会错（深色→浅色时快照渲成浅色，直接盖在深色屏上 = 一次硬闪）。
        // 用 performAsCurrentDrawingAppearance 把旧外观设为当前绘制外观，再取 .nsImage。
        let oldAppearance = NSAppearance(named: currentScheme == .dark ? .darkAqua : .aqua)
        var rendered: NSImage?
        if let oldAppearance {
            oldAppearance.performAsCurrentDrawingAppearance {
                rendered = renderer.nsImage
            }
        } else {
            rendered = renderer.nsImage
        }
        guard let nsImage = rendered else { return }

        transitionToken &+= 1
        let token = transitionToken
        snapshotOpacity = 1
        transitionSnapshot = Image(nsImage: nsImage)

        // 下一拍再启动淡出，确保快照先以满不透明度渲染一帧、完整盖住瞬切。
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.4)) {
                self.snapshotOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                // 期间又触发了新的切换则跳过，避免提前清掉新快照。
                if self.transitionToken == token {
                    self.transitionSnapshot = nil
                }
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 0) {
            HStack {
                // Logo
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Theme.Colors.logoStart, Theme.Colors.logoEnd],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 22, height: 22)

                        Image(systemName: "flame.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.Colors.onPrimary)  // 白色 flame 在橙色 logo 圆背景上
                    }

                    Text("ClaudeMeter")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Colors.textPrimary)
                }

                Spacer()

                // Loading indicator
                if usageManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                        .tint(Theme.Colors.textSecondary)
                }

                // Last update
                Text("更新于 \(formatTime(usageManager.lastUpdate))")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Colors.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // View mode toggle
            HStack(spacing: 0) {
                viewModeButton("今日", tag: 0)
                viewModeButton("历史", tag: 1)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(Theme.Colors.bgCard)
    }

    private func viewModeButton(_ title: String, tag: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewMode = tag
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(viewMode == tag ? Theme.Colors.primary : Color.clear)
                    .frame(width: 6, height: 6)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(viewMode == tag ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(viewMode == tag ? Theme.Colors.bgSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Main Stats Card

    private var mainStatsCard: some View {
        VStack(spacing: 16) {
            // Usage display - large display
            VStack(spacing: 6) {
                Text(viewMode == 0 ? "今日使用" : "累计使用")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.Colors.textTertiary)
                    .tracking(1)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    // filteredBreakdown 内部 viewMode==0 时已经返回 todayBreakdown 真实值，不必再分支
                    Text(formatTokenCount(filteredBreakdown.total))
                        .font(Theme.Typography.displayHuge)
                        .foregroundStyle(Theme.Colors.primaryGradient)
                        // 刷新时数字滚动而不是直接跳变
                        .contentTransition(.numericText(value: Double(filteredBreakdown.total)))
                        .animation(Theme.Motion.numericRoll, value: filteredBreakdown.total)

                    Text("tokens")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.Colors.textTertiary)
                }

                // Comparison with yesterday (only in today mode)
                if viewMode == 0 && yesterdayData > 0 {
                    comparisonBadge
                }
            }

            // Token breakdown — 全用 filteredBreakdown 真实值，不再做错误的月度比例缩放
            HStack(spacing: 12) {
                tokenBreakdownItem("输入", filteredBreakdown.input, Theme.Colors.inputColor)
                tokenBreakdownItem("输出", filteredBreakdown.output, Theme.Colors.outputColor)
                tokenBreakdownItem("缓存", filteredBreakdown.cacheRead + filteredBreakdown.cacheCreation, Theme.Colors.cacheColor)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.Colors.bgCard)
        )
    }

    private var comparisonBadge: some View {
        let diff = usageManager.todayBreakdown.total - yesterdayData
        let percentage = yesterdayData > 0 ? Double(abs(diff)) / Double(yesterdayData) * 100 : 0
        let isUp = diff >= 0
        // Token 增减是中性事件，不强行赋予好坏含义。增 = 蓝（呼应 input 色），减 = 灰
        let tint = isUp ? Theme.Colors.trendUp : Theme.Colors.trendDown

        return HStack(spacing: 4) {
            Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 10, weight: .bold))
            Text(String(format: "%.0f%%", percentage))
                .font(Theme.Typography.label)
            Text("较昨日")
                .font(.system(size: 10))
                .opacity(Theme.TextOpacity.secondary)
        }
        .foregroundColor(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(tint.opacity(0.15))
        )
    }

    private func tokenBreakdownItem(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(Theme.Typography.captionMedium)
                .foregroundColor(color)

            Text(formatTokenCount(value))
                .font(Theme.Typography.statBody)
                .foregroundColor(color)
                .contentTransition(.numericText(value: Double(value)))
                .animation(Theme.Motion.numericRoll, value: value)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(color.opacity(0.15))
        )
    }

    // MARK: - Chart Section

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(viewMode == 0 ? "每日趋势" : "历史趋势")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Colors.textTertiary)

                Spacer()

                if viewMode == 0 {
                    Text("最近 7 天")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Colors.textTertiary)
                } else {
                    // History mode: 月/周/日 切换
                    periodPicker
                }
            }

            if viewMode == 0 {
                // Today mode: Bar chart
                barChartView
            } else {
                // History mode: Line chart
                lineChartView
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.Colors.bgCard)
        )
    }

    /// 历史模式下的周期切换器：月 / 周 / 日。
    private var periodPicker: some View {
        HStack(spacing: 2) {
            periodChip("月", tag: 0)
            periodChip("周", tag: 1)
            periodChip("日", tag: 2)
        }
        .padding(2)
        .background(Capsule().fill(Theme.Colors.bgElevated))
    }

    private func periodChip(_ label: String, tag: Int) -> some View {
        Button {
            withAnimation(Theme.Motion.quick) {
                historyPeriod = tag
                hoveredLineIndex = nil
            }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(historyPeriod == tag ? Theme.Colors.onPrimary : Theme.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(historyPeriod == tag ? Theme.Colors.primary : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bar Chart (Today mode)

    private var barChartView: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width - 8
            let barWidth = totalWidth / CGFloat(chartData.count) - 4

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(chartData.indices, id: \.self) { index in
                    let item = chartData[index]
                    let maxVal = max(1, chartData.map(\.tokens).max() ?? 1)
                    let height = CGFloat(item.tokens) / CGFloat(maxVal) * 50
                    let isHovered = hoveredBarIndex == index

                    VStack(spacing: 3) {
                        Text(formatTokenCount(item.tokens))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(isHovered ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Colors.primaryGradient)
                            .frame(width: barWidth, height: max(height, 3))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.white.opacity(isHovered ? 0.5 : 0), lineWidth: 1)
                            )
                            .scaleEffect(x: 1, y: isHovered ? 1.05 : 1.0, anchor: .bottom)

                        Text(item.label)
                            .font(.system(size: 10))
                            .foregroundColor(isHovered ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)
                    }
                    .frame(width: barWidth)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(Theme.Motion.quick) {
                            hoveredBarIndex = hovering ? index : nil
                        }
                    }
                }
            }
            .frame(width: geometry.size.width)
            // 数据切换时柱子高度从旧值平滑插值到新值
            .animation(Theme.Motion.chartUpdate, value: chartData.map(\.tokens))
        }
        .frame(height: 85)
    }

    // MARK: - Line Chart (History mode)

    private var lineChartView: some View {
        let data = chartData
        let maxVal = max(1, data.map(\.tokens).max() ?? 1)
        let chartHeight: CGFloat = 65
        let padding: CGFloat = 8
        let minPointSpacing: CGFloat = 36  // 每个数据点至少占 36pt，超出则横向滚动

        return GeometryReader { outer in
            let availableWidth = outer.size.width
            // 用 max() 让内容宽度 ≥ 可视宽度：少时 stretch 撑满，多时超出可滚动
            let neededWidth = CGFloat(max(data.count - 1, 1)) * minPointSpacing + padding * 2
            let actualWidth = max(availableWidth, neededWidth)
            let chartWidth = actualWidth - padding * 2
            let stepX = chartWidth / CGFloat(max(data.count - 1, 1))
            // 单点时居中；多点时按 stepX 均布。
            let xOf: (Int) -> CGFloat = { idx in
                data.count == 1 ? actualWidth / 2 : padding + stepX * CGFloat(idx)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 2) {
                    // ── 图表绘制区 ──
                    ZStack {
                        // Grid lines
                        VStack(spacing: 0) {
                            ForEach(0..<3) { _ in
                                Rectangle()
                                    .fill(Theme.Colors.bgElevated)
                                    .frame(height: 1)
                                Spacer()
                            }
                        }

                        // 折线 + 渐变填充只在 ≥2 个点时画（单点没有"线"）
                        if data.count >= 2 {
                            // 渐变填充
                            Path { path in
                                for (index, item) in data.enumerated() {
                                    let x = xOf(index)
                                    let y = chartHeight - 5 - (CGFloat(item.tokens) / CGFloat(maxVal) * (chartHeight - 15))
                                    if index == 0 {
                                        path.move(to: CGPoint(x: x, y: y))
                                    } else {
                                        path.addLine(to: CGPoint(x: x, y: y))
                                    }
                                }
                                path.addLine(to: CGPoint(x: xOf(data.count - 1), y: chartHeight))
                                path.addLine(to: CGPoint(x: xOf(0), y: chartHeight))
                                path.closeSubpath()
                            }
                            .fill(
                                LinearGradient(
                                    colors: [Theme.Colors.primary.opacity(0.3), Theme.Colors.primaryDeep.opacity(0.05)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )

                            // 折线
                            Path { path in
                                for (index, item) in data.enumerated() {
                                    let x = xOf(index)
                                    let y = chartHeight - 5 - (CGFloat(item.tokens) / CGFloat(maxVal) * (chartHeight - 15))
                                    if index == 0 {
                                        path.move(to: CGPoint(x: x, y: y))
                                    } else {
                                        path.addLine(to: CGPoint(x: x, y: y))
                                    }
                                }
                            }
                            .stroke(
                                LinearGradient(
                                    colors: [Theme.Colors.primary, Theme.Colors.primaryDeep],
                                    startPoint: .leading, endPoint: .trailing
                                ),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                            )
                        }

                        // 数据点 + label + tooltip：≥1 个点就画（兼容单点情况）
                        if !data.isEmpty {
                            ForEach(data.indices, id: \.self) { index in
                                let item = data[index]
                                let x = xOf(index)
                                let y = chartHeight - 5 - (CGFloat(item.tokens) / CGFloat(maxVal) * (chartHeight - 15))
                                let isHovered = hoveredLineIndex == index
                                let isDefault = index == 0 || index == data.count - 1 || item.tokens == maxVal

                                Circle()
                                    .fill(Theme.Colors.primary)
                                    .frame(width: isHovered ? 7 : 4, height: isHovered ? 7 : 4)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white.opacity(isHovered ? 0.5 : 0), lineWidth: 1)
                                    )
                                    .position(x: x, y: y)

                                // 默认显示首末/最高点的简略 label
                                if !isHovered && isDefault && hoveredLineIndex == nil {
                                    Text(formatTokenCount(item.tokens))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(Theme.Colors.textSecondary)
                                        .position(x: x, y: y - 12)
                                }
                            }

                            // Hover tooltip
                            if let idx = hoveredLineIndex, idx < data.count {
                                let hovered = data[idx]
                                let hx = xOf(idx)
                                let hy = chartHeight - 5 - (CGFloat(hovered.tokens) / CGFloat(maxVal) * (chartHeight - 15))

                                VStack(spacing: 1) {
                                    Text(formatTooltipDate(hovered.date, period: historyPeriod))
                                        .font(.system(size: 9))
                                        .foregroundColor(Theme.Colors.textSecondary)
                                    Text("\(formatTokenCount(hovered.tokens)) tokens")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(Theme.Colors.textPrimary)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Theme.Colors.bgCard)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 5)
                                                .stroke(Theme.Colors.border, lineWidth: 0.5)
                                        )
                                        .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
                                )
                                .fixedSize()
                                .position(
                                    x: max(40, min(actualWidth - 40, hx)),
                                    y: max(14, hy - 22)
                                )
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                            }
                        }
                    }
                    .frame(width: actualWidth, height: chartHeight)
                    .animation(Theme.Motion.chartUpdate, value: data.map(\.tokens))
                    // 用单个 onContinuousHover 挂在整个图表区，从鼠标 x 算最近数据点。
                    // 比给每个点单独 .onHover 更可靠 —— .onHover 在 ScrollView 里会被吞掉。
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard !data.isEmpty else { return }
                            let raw = (location.x - padding) / stepX
                            let idx = max(0, min(data.count - 1, Int(raw.rounded())))
                            if hoveredLineIndex != idx {
                                withAnimation(Theme.Motion.quick) {
                                    hoveredLineIndex = idx
                                }
                            }
                        case .ended:
                            withAnimation(Theme.Motion.quick) {
                                hoveredLineIndex = nil
                            }
                        }
                    }

                    // X-axis labels（跟数据点 x 对齐）
                    ZStack {
                        ForEach(data.indices, id: \.self) { index in
                            Text(data[index].label)
                                .font(.system(size: 10))
                                .foregroundColor(Theme.Colors.textTertiary)
                                .position(x: xOf(index), y: 6)
                        }
                    }
                    .frame(width: actualWidth, height: 14)
                }
            }
        }
        .frame(height: 88)
    }

    // MARK: - Tab Content

    private var tabContentSection: some View {
        VStack(spacing: 12) {
            // Tab picker
            HStack(spacing: 4) {
                tabButton("项目", tag: 0, icon: "folder.fill")
                tabButton("模型", tag: 1, icon: "cpu.fill")
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.Colors.bgElevated)
            )

            // Content
            if selectedTab == 0 {
                projectListView
            } else {
                modelListView
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.Colors.bgCard)
        )
    }

    private func tabButton(_ title: String, tag: Int, icon: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tag
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundColor(selectedTab == tag ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedTab == tag ? Theme.Colors.primary : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Project List

    private var projectListView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            let data = viewMode == 0 ? usageManager.todayProjectData : usageManager.getProjectData(forMonth: nil)
            if data.isEmpty {
                emptyStateView(
                    icon: "tray",
                    title: viewMode == 0 ? "今日还没有项目数据" : "暂无项目数据",
                    hint: viewMode == 0 ? "开启一次 Claude Code 对话，刷新即可看到" : nil
                )
            } else {
                VStack(spacing: 4) {
                    ForEach(data, id: \.originalName) { project in
                        projectRow(project, maxTotal: data.first?.details.total ?? 1)
                    }
                }
            }
        }
        .frame(maxHeight: 220)
    }

    private func projectRow(_ project: UsageManager.ProjectData, maxTotal: Int) -> some View {
        let total = project.details.total
        let ratio = Double(total) / Double(maxTotal)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.Colors.textPrimary)

                    Text(ProjectPath.fullPath(project.originalName))
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatTokenCount(total))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.Colors.primary)

                    Text("\(Int(ratio * 100))%")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Colors.textTertiary)
                }
            }

            // Mini stats
            HStack(spacing: 16) {
                miniStatInline("输入", project.details.input, Theme.Colors.inputColor)
                miniStatInline("输出", project.details.output, Theme.Colors.outputColor)
                miniStatInline("缓存", project.details.cacheRead, Theme.Colors.cacheColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.Colors.bgElevated)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            // 点击整个卡片
        }
    }

    // MARK: - Model List

    private var modelListView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            let data = viewMode == 0 ? usageManager.todayModelData : usageManager.getModelData(forMonth: nil)
            if data.isEmpty {
                emptyStateView(
                    icon: "cpu",
                    title: viewMode == 0 ? "今日还没有模型数据" : "暂无模型数据",
                    hint: nil
                )
            } else {
                VStack(spacing: 4) {
                    ForEach(data, id: \.model) { model in
                        modelRow(model, maxTotal: data.first?.details.total ?? 1)
                    }
                }
            }
        }
        .frame(maxHeight: 220)
    }

    /// 通用空状态：图标 + 主文案 + 可选引导。
    private func emptyStateView(icon: String, title: String, hint: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundColor(Theme.Colors.textDisabled)
            Text(title)
                .font(Theme.Typography.label)
                .foregroundColor(Theme.Colors.textSecondary)
            if let hint = hint {
                Text(hint)
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func modelRow(_ model: (model: String, cost: Double, details: TokenBreakdown), maxTotal: Int) -> some View {
        let total = model.details.total
        let ratio = Double(total) / Double(maxTotal)
        let color = modelColor(model.model)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)

                    Text(model.model)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.Colors.textPrimary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatTokenCount(total))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(color)

                    Text("\(Int(ratio * 100))%")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Colors.textTertiary)
                }
            }

            // Mini stats
            HStack(spacing: 16) {
                miniStatInline("输入", model.details.input, Theme.Colors.inputColor)
                miniStatInline("输出", model.details.output, Theme.Colors.outputColor)
                miniStatInline("缓存", model.details.cacheRead, Theme.Colors.cacheColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.Colors.bgElevated)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            // 点击整个卡片
        }
    }

    // MARK: - Footer
    // Layout 哲学：主 CTA "刷新" 占 primary 色，"设置" 弱化为 secondary，
    // 破坏性的 "退出" 收成 icon-only，避免比刷新还显眼。
    private var footerView: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Primary CTA - 刷新
            Button {
                usageManager.loadData(showLoading: true)
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.Typography.label)
                    Text("刷新")
                        .font(Theme.Typography.label)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Theme.Colors.primaryGradient)
                .foregroundColor(Theme.Colors.onPrimary)
                .cornerRadius(Theme.Radius.sm)
            }
            .buttonStyle(.plain)
            .disabled(usageManager.isLoading)
            .opacity(usageManager.isLoading ? 0.5 : 1)

            // Secondary - 设置
            Button {
                withAnimation(Theme.Motion.standard) {
                    showSettings = true
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "gearshape.fill")
                        .font(Theme.Typography.label)
                    Text("设置")
                        .font(Theme.Typography.label)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Theme.Colors.bgElevated)
                .foregroundColor(Theme.Colors.textPrimary)
                .cornerRadius(Theme.Radius.sm)
            }
            .buttonStyle(.plain)

            // Tertiary - 退出（icon-only，最弱）
            Button {
                onQuit()
            } label: {
                Image(systemName: "power")
                    .font(Theme.Typography.label)
                    .frame(width: 36, height: 32)
                    .background(Theme.Colors.bgElevated)
                    .foregroundColor(Theme.Colors.textTertiary)
                    .cornerRadius(Theme.Radius.sm)
            }
            .buttonStyle(.plain)
            .help("退出 ClaudeMeter")
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.bgCard)
    }

    // MARK: - Helper Views

    private func miniStatInline(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color.opacity(0.5))
                .frame(width: 3, height: 3)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Theme.Colors.textTertiary)
            Text(formatTokenCount(value))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(color)
        }
    }

    // MARK: - Helper Functions

    private func formatTokenCount(_ value: Int) -> String {
        let settings = SettingsManager.shared
        if settings.tokenFormat == 1 {
            // Chinese format
            if value >= 10_000_000 {
                return String(format: "%.1f千万", Double(value) / 10_000_000)
            } else if value >= 10_000 {
                return String(format: "%.1f万", Double(value) / 10_000)
            }
            return String(value)
        } else {
            // English format
            if value >= 1_000_000 {
                return String(format: "%.1fM", Double(value) / 1_000_000)
            } else if value >= 1_000 {
                return String(format: "%.1fK", Double(value) / 1_000)
            }
            return String(value)
        }
    }

    private func formatTime(_ date: Date) -> String {
        fmtTime.string(from: date)
    }

    private func formatDateKey(_ date: Date) -> String {
        fmtDayKey.string(from: date)
    }

    private func parseDate(_ str: String) -> Date? {
        fmtDayKey.date(from: str)
    }

    private func formatChartLabel(_ date: Date) -> String {
        fmtChartLabel.string(from: date)
    }

    /// 折线图悬停 tooltip 的日期格式。按周期粒度返回不同格式：
    /// - 月：「2026年3月」
    /// - 周：「2026/3/8 起」（自然周起始日）
    /// - 日：「2026/3/15 周日」（带年份和星期）
    private func formatTooltipDate(_ date: Date, period: Int = 2) -> String {
        switch period {
        case 0:  return fmtTooltipMonth.string(from: date)
        case 1:  return fmtTooltipWeek.string(from: date)
        default: return fmtTooltipDay.string(from: date)
        }
    }

    private func modelColor(_ name: String) -> Color {
        let lower = name.lowercased()
        if lower.contains("opus") { return Theme.Colors.modelOpus }
        if lower.contains("sonnet") { return Theme.Colors.primary }
        if lower.contains("haiku") { return Theme.Colors.modelHaiku }
        if lower.contains("qwen") { return Theme.Colors.modelQwen }
        if lower.contains("pitaya") { return Theme.Colors.modelPitaya }
        return Theme.Colors.modelOther
    }
}

