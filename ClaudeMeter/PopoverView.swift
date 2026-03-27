import SwiftUI

// MARK: - Data Models

struct DayData: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let tokens: Int
    let input: Int
    let output: Int
    let cacheRead: Int
    let modelBreakdown: [ModelData]

    static func == (lhs: DayData, rhs: DayData) -> Bool {
        lhs.id == rhs.id
    }
}

struct ModelData: Identifiable {
    let id = UUID()
    let name: String
    let input: Int
    let output: Int
    let cacheRead: Int

    var displayName: String {
        // 提取更友好的模型名
        let lower = name.lowercased()
        if lower.contains("opus") { return "Opus" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("haiku") { return "Haiku" }
        if lower.contains("qwen") { return "Qwen" }
        if lower.contains("pitaya") { return "Pitaya" }
        // 截取前 15 个字符
        return String(name.prefix(15))
    }

    var totalTokens: Int {
        input + output + cacheRead
    }
}

// MARK: - Popover View

struct PopoverView: View {
    @ObservedObject var usageManager: UsageManager
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    @State private var selectedTab: Int = 0
    @State private var viewMode: Int = 0  // 0 = today, 1 = history
    @State private var selectedMonth: String? = nil  // nil = all, or "2026-03" etc.
    @State private var showMonthPicker: Bool = false

    // MARK: - Computed Properties

    private var todayData: (tokens: Int, input: Int, output: Int, cache: Int) {
        let todayStr = formatDateKey(Date())
        if let todayEntry = usageManager.dailyData.first(where: { $0.date == todayStr }) {
            let total = todayEntry.tokens
            // 需要从 entries 中获取详细数据，这里用月度数据近似
            if let month = usageManager.monthlyData.first {
                let dayRatio = Double(total) / Double(month.details.total)
                return (
                    tokens: total,
                    input: Int(Double(month.details.input) * dayRatio),
                    output: Int(Double(month.details.output) * dayRatio),
                    cache: Int(Double(month.details.cacheRead + month.details.cacheCreation) * dayRatio)
                )
            }
            return (tokens: total, input: 0, output: 0, cache: 0)
        }
        return (tokens: 0, input: 0, output: 0, cache: 0)
    }

    private var yesterdayData: Int {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let yesterdayStr = formatDateKey(yesterday)
        if let entry = usageManager.dailyData.first(where: { $0.date == yesterdayStr }) {
            return entry.tokens
        }
        return 0
    }

    private var totalData: (tokens: Int, input: Int, output: Int, cache: Int) {
        var tokens = 0, input = 0, output = 0, cache = 0
        for entry in usageManager.monthlyData {
            tokens += entry.details.total
            input += entry.details.input
            output += entry.details.output
            cache += entry.details.cacheRead + entry.details.cacheCreation
        }
        return (tokens, input, output, cache)
    }

    private var dailyChartData: [(date: Date, tokens: Int, label: String)] {
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
            // History mode: filtered by selectedMonth
            let dailyData = usageManager.getDailyData(forMonth: selectedMonth)
            return dailyData.map { dateStr, tokens in
                let date = parseDate(dateStr) ?? Date()
                let label = formatChartLabel(date)
                return (date: date, tokens: tokens, label: label)
            }
        }
    }

    private var filteredBreakdown: TokenBreakdown {
        if viewMode == 0 {
            return usageManager.todayBreakdown
        } else {
            return usageManager.getBreakdown(forMonth: selectedMonth)
        }
    }

    typealias TokenBreakdown = UsageManager.TokenBreakdown

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Content
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    // Main Stats Card
                    mainStatsCard

                    // Daily Chart
                    chartSection

                    // Tab Content
                    tabContentSection
                }
                .padding(16)
            }

            // Footer
            footerView
        }
        .frame(width: 360, height: 540)
        .background(Color(hex: "0f0f1a"))
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
                                    colors: [Color(hex: "FF6B35"), Color(hex: "F7931E")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 22, height: 22)

                        Image(systemName: "flame.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }

                    Text("ClaudeMeter")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }

                Spacer()

                // Loading indicator
                if usageManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                        .tint(.white.opacity(0.7))
                }

                // Last update
                Text("更新于 \(formatTime(usageManager.lastUpdate))")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.5))
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
        .background(Color(hex: "1a1a2e"))
    }

    private func viewModeButton(_ title: String, tag: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewMode = tag
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(viewMode == tag ? Color(hex: "667eea") : Color.clear)
                    .frame(width: 6, height: 6)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(viewMode == tag ? .white : .white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(viewMode == tag ? Color.white.opacity(0.1) : Color.clear)
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
                Text(viewMode == 0 ? "今日使用" : (selectedMonth == nil ? "累计使用" : formatMonthLabel(selectedMonth)))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .tracking(1)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatTokenCount(viewMode == 0 ? todayData.tokens : filteredBreakdown.total))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "667eea"), Color(hex: "764ba2")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text("tokens")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }

                // Comparison with yesterday (only in today mode)
                if viewMode == 0 && yesterdayData > 0 {
                    comparisonBadge
                }
            }

            // Token breakdown
            HStack(spacing: 12) {
                tokenBreakdownItem("输入", viewMode == 0 ? todayData.input : filteredBreakdown.input, Color(hex: "4facfe"))
                tokenBreakdownItem("输出", viewMode == 0 ? todayData.output : filteredBreakdown.output, Color(hex: "00f2fe"))
                tokenBreakdownItem("缓存", viewMode == 0 ? todayData.cache : (filteredBreakdown.cacheRead + filteredBreakdown.cacheCreation), Color(hex: "fa709a"))
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(hex: "1a1a2e"))
        )
    }

    private var comparisonBadge: some View {
        let diff = todayData.tokens - yesterdayData
        let percentage = yesterdayData > 0 ? Double(abs(diff)) / Double(yesterdayData) * 100 : 0
        let isUp = diff >= 0

        return HStack(spacing: 4) {
            Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
            Text(String(format: "%.0f%%", percentage))
                .font(.system(size: 11, weight: .semibold))
            Text("较昨日")
                .font(.system(size: 9))
                .opacity(0.7)
        }
        .foregroundColor(isUp ? .orange : .green)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isUp ? Color.orange.opacity(0.2) : Color.green.opacity(0.2))
        )
    }

    private func tokenBreakdownItem(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(color)

            Text(formatTokenCount(value))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.15))
        )
    }

    // MARK: - Chart Section

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(viewMode == 0 ? "每日趋势" : "历史趋势")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))

                Spacer()

                if viewMode == 0 {
                    Text("最近 7 天")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                } else {
                    // Month filter picker
                    monthFilterPicker
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
                .fill(Color(hex: "1a1a2e"))
        )
    }

    private var monthFilterPicker: some View {
        Button {
            showMonthPicker.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(selectedMonth == nil ? "全部" : formatMonthLabel(selectedMonth))
                    .font(.system(size: 9, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color(hex: "667eea"))
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showMonthPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    selectedMonth = nil
                    showMonthPicker = false
                } label: {
                    HStack {
                        if selectedMonth == nil {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10))
                        } else {
                            Spacer().frame(width: 14)
                        }
                        Text("全部")
                            .font(.system(size: 11))
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider()
                    .background(Color.white.opacity(0.2))

                ForEach(usageManager.availableMonths, id: \.self) { month in
                    Button {
                        selectedMonth = month
                        showMonthPicker = false
                    } label: {
                        HStack {
                            if selectedMonth == month {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10))
                            } else {
                                Spacer().frame(width: 14)
                            }
                            Text(formatMonthLabel(month))
                                .font(.system(size: 11))
                            Spacer()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
            .frame(minWidth: 120)
            .background(Color(hex: "1a1a2e"))
        }
    }

    // MARK: - Bar Chart (Today mode)

    private var barChartView: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width - 8
            let barWidth = totalWidth / CGFloat(dailyChartData.count) - 4

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(dailyChartData.indices, id: \.self) { index in
                    let item = dailyChartData[index]
                    let maxVal = max(1, dailyChartData.map(\.tokens).max() ?? 1)
                    let height = CGFloat(item.tokens) / CGFloat(maxVal) * 50

                    VStack(spacing: 3) {
                        Text(formatTokenCount(item.tokens))
                            .font(.system(size: 7, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))

                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "667eea"), Color(hex: "764ba2")],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: barWidth, height: max(height, 3))

                        Text(item.label)
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .frame(width: barWidth)
                }
            }
            .frame(width: geometry.size.width)
        }
        .frame(height: 85)
    }

    // MARK: - Line Chart (History mode)

    private var lineChartView: some View {
        let data = dailyChartData
        let maxVal = max(1, data.map(\.tokens).max() ?? 1)

        return VStack(spacing: 4) {
            // Chart area with dates - combined for alignment
            GeometryReader { geometry in
                let width = geometry.size.width
                let padding: CGFloat = 8
                let chartWidth = width - padding * 2
                let chartHeight: CGFloat = 65
                let stepX = chartWidth / CGFloat(max(data.count - 1, 1))

                VStack(spacing: 2) {
                    // Line chart
                    ZStack {
                        // Grid lines
                        VStack(spacing: 0) {
                            ForEach(0..<3) { _ in
                                Rectangle()
                                    .fill(Color.white.opacity(0.05))
                                    .frame(height: 1)
                                Spacer()
                            }
                        }

                        // Line path
                        if data.count >= 2 {
                            // Gradient fill under the line
                            Path { path in
                                for (index, item) in data.enumerated() {
                                    let x = padding + stepX * CGFloat(index)
                                    let y = chartHeight - 5 - (CGFloat(item.tokens) / CGFloat(maxVal) * (chartHeight - 15))

                                    if index == 0 {
                                        path.move(to: CGPoint(x: x, y: y))
                                    } else {
                                        path.addLine(to: CGPoint(x: x, y: y))
                                    }
                                }
                                let lastX = padding + stepX * CGFloat(data.count - 1)
                                let firstX = padding
                                path.addLine(to: CGPoint(x: lastX, y: chartHeight))
                                path.addLine(to: CGPoint(x: firstX, y: chartHeight))
                                path.closeSubpath()
                            }
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "667eea").opacity(0.3), Color(hex: "764ba2").opacity(0.05)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                            // Line
                            Path { path in
                                for (index, item) in data.enumerated() {
                                    let x = padding + stepX * CGFloat(index)
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
                                    colors: [Color(hex: "667eea"), Color(hex: "764ba2")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                            )

                            // Data points with token labels
                            ForEach(data.indices, id: \.self) { index in
                                let item = data[index]
                                let x = padding + stepX * CGFloat(index)
                                let y = chartHeight - 5 - (CGFloat(item.tokens) / CGFloat(maxVal) * (chartHeight - 15))

                                // Show point
                                Circle()
                                    .fill(Color(hex: "667eea"))
                                    .frame(width: 4, height: 4)
                                    .position(x: x, y: y)

                                // Show token label for first, last, and max points
                                if index == 0 || index == data.count - 1 || item.tokens == maxVal {
                                    Text(formatTokenCount(item.tokens))
                                        .font(.system(size: 7, weight: .medium))
                                        .foregroundColor(.white.opacity(0.6))
                                        .position(x: x, y: y - 10)
                                }
                            }
                        }
                    }
                    .frame(height: chartHeight)

                    // X-axis dates - aligned with data points using overlay
                    ZStack {
                        ForEach(data.indices, id: \.self) { index in
                            Text(data[index].label)
                                .font(.system(size: 7))
                                .foregroundColor(.white.opacity(0.4))
                                .position(x: padding + stepX * CGFloat(index), y: 6)
                        }
                    }
                    .frame(height: 14)
                }
            }
            .frame(height: 88)
        }
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
                    .fill(Color.white.opacity(0.05))
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
                .fill(Color(hex: "1a1a2e"))
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
            .foregroundColor(selectedTab == tag ? .white : .white.opacity(0.5))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedTab == tag ? Color(hex: "667eea") : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Project List

    private var projectListView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            let data = viewMode == 0 ? usageManager.todayProjectData : usageManager.getProjectData(forMonth: selectedMonth)
            if data.isEmpty {
                Text(viewMode == 0 ? "今日暂无项目数据" : "暂无项目数据")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
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
                        .foregroundColor(.white)

                    Text(fullProjectPath(project.originalName))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatTokenCount(total))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "667eea"))

                    Text("\(Int(ratio * 100))%")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            // Mini stats
            HStack(spacing: 16) {
                miniStatInline("输入", project.details.input, Color(hex: "4facfe"))
                miniStatInline("输出", project.details.output, Color(hex: "00f2fe"))
                miniStatInline("缓存", project.details.cacheRead, Color(hex: "fa709a"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.03))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            // 点击整个卡片
        }
    }

    // MARK: - Model List

    private var modelListView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            let data = viewMode == 0 ? usageManager.todayModelData : usageManager.getModelData(forMonth: selectedMonth)
            if data.isEmpty {
                Text(viewMode == 0 ? "今日暂无模型数据" : "暂无模型数据")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
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
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatTokenCount(total))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(color)

                    Text("\(Int(ratio * 100))%")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            // Mini stats
            HStack(spacing: 16) {
                miniStatInline("输入", model.details.input, Color(hex: "4facfe"))
                miniStatInline("输出", model.details.output, Color(hex: "00f2fe"))
                miniStatInline("缓存", model.details.cacheRead, Color(hex: "fa709a"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.03))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            // 点击整个卡片
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 8) {
            Button {
                usageManager.loadData(showLoading: true)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                    Text("刷新")
                        .font(.system(size: 10, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.08))
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(usageManager.isLoading)
            .opacity(usageManager.isLoading ? 0.5 : 1)

            Button {
                onOpenSettings()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 10, weight: .medium))
                    Text("设置")
                        .font(.system(size: 10, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.08))
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            Button {
                onQuit()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 10, weight: .medium))
                    Text("退出")
                        .font(.system(size: 10, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.2))
                .foregroundColor(.red)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color(hex: "1a1a2e"))
    }

    // MARK: - Helper Views

    private func miniStatInline(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color.opacity(0.5))
                .frame(width: 3, height: 3)
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.4))
            Text(formatTokenCount(value))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
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
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func formatDateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func parseDate(_ str: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: str)
    }

    private func formatChartLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private func formatMonthLabel(_ month: String?) -> String {
        guard let month = month else { return "全部" }
        // Input: "2026-03", Output: "2026年3月"
        let parts = month.components(separatedBy: "-")
        if parts.count == 2 {
            let year = parts[0]
            let monthNum = Int(parts[1]) ?? 1
            return "\(year)年\(monthNum)月"
        }
        return month
    }

    private func simplifyName(_ name: String) -> String {
        if name.isEmpty || name == "unknown" {
            return "Unknown Project"
        }

        if !name.hasPrefix("-Users-") {
            return name
        }

        // 1. 先把连续的 - 替换成单个 -
        var path = name
        while path.contains("--") {
            path = path.replacingOccurrences(of: "--", with: "-")
        }

        // 2. 把 - 替换成 /
        path = path.replacingOccurrences(of: "-", with: "/")

        // 3. 删除开头多余的 /
        if path.hasPrefix("/") {
            path = String(path.dropFirst())
        }

        // 4. 按 / 分割，取最后一个作为项目名
        let parts = path.components(separatedBy: "/").filter { !$0.isEmpty }
        return parts.last ?? name
    }

    private func fullProjectPath(_ name: String) -> String {
        if !name.hasPrefix("-Users-") {
            return name
        }

        // 1. 先把连续的 - 替换成单个 -
        var path = name
        while path.contains("--") {
            path = path.replacingOccurrences(of: "--", with: "-")
        }

        // 2. 把 - 替换成 /
        path = path.replacingOccurrences(of: "-", with: "/")

        // 3. 确保开头有 /
        if !path.hasPrefix("/") {
            path = "/" + path
        }

        return path
    }

    private func simplifyModelName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("opus") { return "Opus" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("haiku") { return "Haiku" }
        if lower.contains("qwen") { return "Qwen" }
        if lower.contains("pitaya") { return "Pitaya" }
        return String(name.prefix(20))
    }

    private func modelColor(_ name: String) -> Color {
        let lower = name.lowercased()
        if lower.contains("opus") { return Color(hex: "E879F9") }
        if lower.contains("sonnet") { return Color(hex: "667eea") }
        if lower.contains("haiku") { return Color(hex: "34D399") }
        if lower.contains("qwen") { return Color(hex: "F59E0B") }
        if lower.contains("pitaya") { return Color(hex: "FB7185") }
        return Color(hex: "6B7280")
    }
}

// MARK: - Color Extension

extension Color {
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

// MARK: - Color Extension
