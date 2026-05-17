//
//  UsageManager.swift
//  ClaudeMeter
//
//  数据加载与聚合：
//    - 启动时直接从 DB 读取并展示历史数据
//    - 后续刷新走增量扫描（按文件指纹跳过未变化的）
//    - 跨进程重启数据持久化在 SwiftData 里
//

import Foundation
import Combine
import SwiftData
import os.log

private let umLogger = Logging.logger("UsageManager")

// MARK: - Usage Entry (Top-level for DataStore access)

struct UsageEntry {
    let timestamp: String
    let date: String  // YYYY-MM-DD
    let month: String // YYYY-MM
    let project: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let costUSD: Double
    /// 入库唯一键。可能是 messageId:requestId，也可能是 loc:path:line 兜底。
    let uniqueHash: String?
}

class UsageManager: ObservableObject {
    // MARK: - Published Data

    @Published var monthlyData: [(month: String, cost: Double, details: TokenBreakdown)] = []
    @Published var dailyData: [(date: String, tokens: Int)] = []
    @Published var projectData: [ProjectData] = []
    @Published var modelData: [(model: String, cost: Double, details: TokenBreakdown)] = []
    @Published var todayProjectData: [ProjectData] = []
    @Published var todayModelData: [(model: String, cost: Double, details: TokenBreakdown)] = []
    @Published var todayBreakdown: TokenBreakdown = TokenBreakdown()
    @Published var currentMonthCost: Double = 0.0
    @Published var totalCost: Double = 0.0
    @Published var lastUpdate: Date = Date()
    @Published var isLoading: Bool = false

    // Available months for filtering
    var availableMonths: [String] {
        monthlyData.map { $0.month }.sorted(by: >)
    }

    // MARK: - Data Structures

    struct ProjectData {
        let displayName: String    // 简化后的名称，用于显示
        let originalName: String   // 原始名称，用于计算完整路径
        let cost: Double
        let details: TokenBreakdown
    }

    struct TokenBreakdown {
        var input: Int = 0
        var cacheCreation: Int = 0
        var cacheRead: Int = 0
        var output: Int = 0
        var total: Int { input + output + cacheCreation + cacheRead }
    }

    // MARK: - Private Properties

    /// 仅缓存一次的 formatters。`DateFormatter` 初始化是重操作，per-call 创建会很慢。
    private let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_CA")  // en-CA 默认 YYYY-MM-DD
        return f
    }()
    private let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f
    }()
    private let fallbackParsers: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd"
        ]
        return formats.map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            return f
        }
    }()

    /// 内存里的全量 entries，用于历史月份切换的 in-memory filter。
    /// 由 aggregateAndPublish 在主线程更新，保证读写都在主线程。
    private var allEntries: [UsageEntry] = []

    /// 当前正在跑的 refresh 任务。重复调用 loadData 时复用，避免并发扫描。
    private var refreshTask: Task<Void, Never>?

    // MARK: - Public API

    init() {
        // Boot 也走 refreshTask 链：先从 DB 出旧数据快照，再做一次增量扫描。
        // StatusBarController.init 之后调 loadData 时会因 refreshTask 还在而 skip，
        // 消除两个 publish 互相覆盖的 race。
        refreshTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.bootFromDatabase()
            await self?.refreshFromDisk()
            await MainActor.run { [weak self] in
                self?.refreshTask = nil
            }
        }
    }

    func loadData(showLoading: Bool = true) {
        // 防并发：已经在跑就直接 return，避免多次扫描堆积。
        if let existing = refreshTask, !existing.isCancelled {
            umLogger.debug("loadData: refresh already in flight, skipping")
            return
        }

        if showLoading {
            DispatchQueue.main.async {
                self.isLoading = true
            }
        }

        refreshTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.refreshFromDisk()
            await MainActor.run { [weak self] in
                self?.refreshTask = nil
            }
        }
    }

    /// 重置数据库，下次 loadData 会全量重建。
    func resetDatabase() {
        Task.detached(priority: .userInitiated) {
            await sharedDataStore.clearAll()
        }
    }

    // MARK: - Boot / Refresh

    /// 启动路径：从 DB 读已有数据，立即聚合发布到 UI。
    private func bootFromDatabase() async {
        let entries = await sharedDataStore.fetchAllRawEntries()
        umLogger.info("Boot from DB: \(entries.count) entries")
        await aggregateAndPublish(entries: entries)
    }

    /// 刷新路径：增量扫描磁盘 → 写入 DB → 重新聚合发布。
    private func refreshFromDisk() async {
        await incrementalScan()
        let entries = await sharedDataStore.fetchAllRawEntries()
        await aggregateAndPublish(entries: entries)
    }

    // MARK: - Incremental Scan

    /// 同步收集所有 JSONL 文件 URL。
    /// 抽出来是因为 NSEnumerator 不是 Sendable，不能在 async 上下文直接 for-in。
    private func collectJSONLFiles() -> [URL] {
        var allFiles: [URL] = []
        for path in getClaudePaths() {
            let projectsPath = path.appendingPathComponent("projects")
            guard let projects = try? FileManager.default.contentsOfDirectory(atPath: projectsPath.path) else {
                continue
            }
            for project in projects {
                let projectPath = projectsPath.appendingPathComponent(project)
                guard let enumerator = FileManager.default.enumerator(
                    at: projectPath,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension == "jsonl" {
                        allFiles.append(fileURL)
                    }
                }
            }
        }
        return allFiles
    }

    /// 扫描所有 JSONL 文件，跳过指纹未变化的，对变化文件 replace 其 entries。
    private func incrementalScan() async {
        let allFiles = collectJSONLFiles()

        // 过滤出真正需要重新解析的文件
        var changed: [(url: URL, project: String, size: Int64, mtime: Date)] = []
        for fileURL in allFiles {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  let mtime = attrs[.modificationDate] as? Date else {
                continue
            }
            let project = extractProjectName(from: fileURL)

            if let cursor = await sharedDataStore.fetchCursor(filePath: fileURL.path),
               cursor.size == size,
               // SwiftData 序列化 Date 可能丢精度，1ms 容差判断「同一个 mtime」
               abs(cursor.mtime.timeIntervalSince1970 - mtime.timeIntervalSince1970) < 0.001 {
                continue  // 文件未变化，跳过
            }
            changed.append((url: fileURL, project: project, size: size, mtime: mtime))
        }

        umLogger.info("Incremental: \(changed.count)/\(allFiles.count) files need re-parse")

        // 对变化文件 replace（删旧+插新+更新 cursor）
        for (fileURL, project, size, mtime) in changed {
            var seen = Set<String>()
            let entries = parseFile(filePath: fileURL, project: project, processedHashes: &seen)
            await sharedDataStore.replaceEntriesForFile(
                filePath: fileURL.path,
                newEntries: entries,
                fileSize: size,
                mtime: mtime
            )
        }
    }

    // MARK: - File Parsing

    /// 解析单个 JSONL。所有返回的 entry 都会带上非空 uniqueHash。
    /// 去重逻辑同 ccusage：(messageId, requestId) 都存在时按此组合去重；否则按 path:line 兜底。
    private func parseFile(filePath: URL, project: String, processedHashes: inout Set<String>) -> [UsageEntry] {
        guard let content = try? String(contentsOf: filePath, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: .newlines)

        // 同一 messageId:requestId 取最后一次出现（流式响应可能多次写入，最后一次是最完整的）
        var lastEntryForHash: [String: (entry: UsageEntry, lineNumber: Int)] = [:]
        // 没有 messageId/requestId 的 entry：合成 path:line 作为兜底 hash
        var unhashedEntries: [(entry: UsageEntry, lineNumber: Int)] = []
        var lineNumber = 0

        for line in lines where !line.isEmpty {
            lineNumber += 1
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard let entry = parseUsageEntry(json: json, project: project) else {
                continue
            }
            if let h = entry.uniqueHash {
                if let existing = lastEntryForHash[h] {
                    if lineNumber > existing.lineNumber {
                        lastEntryForHash[h] = (entry, lineNumber)
                    }
                } else {
                    lastEntryForHash[h] = (entry, lineNumber)
                }
            } else {
                unhashedEntries.append((entry, lineNumber))
            }
        }

        var result: [UsageEntry] = []

        // 跨文件去重：本次扫描中其他文件已处理过此 hash 则跳过
        for (h, tuple) in lastEntryForHash {
            if !processedHashes.contains(h) {
                processedHashes.insert(h)
                result.append(tuple.entry)
            }
        }

        // 合成兜底 hash，让每条无 id 的 entry 也能进 DB
        for (entry, line) in unhashedEntries {
            let synthHash = "loc:\(filePath.path):\(line)"
            result.append(UsageEntry(
                timestamp: entry.timestamp,
                date: entry.date,
                month: entry.month,
                project: entry.project,
                model: entry.model,
                inputTokens: entry.inputTokens,
                outputTokens: entry.outputTokens,
                cacheCreationTokens: entry.cacheCreationTokens,
                cacheReadTokens: entry.cacheReadTokens,
                costUSD: entry.costUSD,
                uniqueHash: synthHash
            ))
        }

        return result
    }

    private func parseUsageEntry(json: [String: Any], project: String) -> UsageEntry? {
        guard let timestamp = json["timestamp"] as? String else { return nil }

        guard let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return nil
        }

        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let cacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0

        // Skip entries with no usage data
        if inputTokens == 0 && outputTokens == 0 && cacheCreationTokens == 0 && cacheReadTokens == 0 {
            return nil
        }

        var model = message["model"] as? String ?? "unknown"
        if let speed = usage["speed"] as? String, speed == "fast" {
            model = "\(model)-fast"
        }

        let costUSD = json["costUSD"] as? Double ?? 0.0

        // ccusage dedup: 仅当 (messageId, requestId) 都存在时去重
        let messageId = message["id"] as? String
        let requestId = json["requestId"] as? String

        let uniqueHash: String?
        if let messageId = messageId, !messageId.isEmpty,
           let requestId = requestId, !requestId.isEmpty {
            uniqueHash = "id:\(messageId):\(requestId)"
        } else {
            uniqueHash = nil
        }

        let date = formatDateFromTimestamp(timestamp)
        let month = String(date.prefix(7))

        return UsageEntry(
            timestamp: timestamp,
            date: date,
            month: month,
            project: project,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: costUSD,
            uniqueHash: uniqueHash
        )
    }

    // MARK: - Aggregation

    /// 单次扫描所有 entries，一次性聚合出 daily / monthly / project / model / today 数据。
    /// 全部计算在 background，最后一次性 dispatch 到 main 更新 @Published。
    private func aggregateAndPublish(entries: [UsageEntry]) async {
        let todayStr = getCurrentDateKey()
        let currentMonth = getCurrentMonthKey()

        var dailyMap: [String: Int] = [:]
        var monthlyMap: [String: TokenBreakdown] = [:]
        var monthlyCost: [String: Double] = [:]
        var projectMap: [String: TokenBreakdown] = [:]
        var projectCost: [String: Double] = [:]
        var modelMap: [String: TokenBreakdown] = [:]
        var modelCost: [String: Double] = [:]
        var todayProjectMap: [String: TokenBreakdown] = [:]
        var todayProjectCost: [String: Double] = [:]
        var todayModelMap: [String: TokenBreakdown] = [:]
        var todayModelCost: [String: Double] = [:]
        var todayBd = TokenBreakdown()

        for e in entries {
            let total = e.inputTokens + e.outputTokens + e.cacheCreationTokens + e.cacheReadTokens
            let cost = entryCost(e)
            dailyMap[e.date, default: 0] += total

            var mb = monthlyMap[e.month] ?? TokenBreakdown()
            mb.input += e.inputTokens
            mb.output += e.outputTokens
            mb.cacheCreation += e.cacheCreationTokens
            mb.cacheRead += e.cacheReadTokens
            monthlyMap[e.month] = mb
            monthlyCost[e.month, default: 0] += cost

            var pb = projectMap[e.project] ?? TokenBreakdown()
            pb.input += e.inputTokens
            pb.output += e.outputTokens
            pb.cacheCreation += e.cacheCreationTokens
            pb.cacheRead += e.cacheReadTokens
            projectMap[e.project] = pb
            projectCost[e.project, default: 0] += cost

            var mdb = modelMap[e.model] ?? TokenBreakdown()
            mdb.input += e.inputTokens
            mdb.output += e.outputTokens
            mdb.cacheCreation += e.cacheCreationTokens
            mdb.cacheRead += e.cacheReadTokens
            modelMap[e.model] = mdb
            modelCost[e.model, default: 0] += cost

            if e.date == todayStr {
                var tpb = todayProjectMap[e.project] ?? TokenBreakdown()
                tpb.input += e.inputTokens
                tpb.output += e.outputTokens
                tpb.cacheCreation += e.cacheCreationTokens
                tpb.cacheRead += e.cacheReadTokens
                todayProjectMap[e.project] = tpb
                todayProjectCost[e.project, default: 0] += cost

                var tmb = todayModelMap[e.model] ?? TokenBreakdown()
                tmb.input += e.inputTokens
                tmb.output += e.outputTokens
                tmb.cacheCreation += e.cacheCreationTokens
                tmb.cacheRead += e.cacheReadTokens
                todayModelMap[e.model] = tmb
                todayModelCost[e.model, default: 0] += cost

                todayBd.input += e.inputTokens
                todayBd.output += e.outputTokens
                todayBd.cacheCreation += e.cacheCreationTokens
                todayBd.cacheRead += e.cacheReadTokens
            }
        }

        let daily = dailyMap.map { (date: $0.key, tokens: $0.value) }
            .sorted { $0.date < $1.date }
        let monthly = monthlyMap.map { (m, b) -> (month: String, cost: Double, details: TokenBreakdown) in
            (month: m, cost: monthlyCost[m] ?? 0, details: b)
        }.sorted { $0.month > $1.month }
        let projects = projectMap.map { (p, b) -> ProjectData in
            ProjectData(displayName: ProjectPath.displayName(p), originalName: p, cost: projectCost[p] ?? 0, details: b)
        }.sorted { $0.details.total > $1.details.total }
        let models = modelMap.map { (m, b) -> (model: String, cost: Double, details: TokenBreakdown) in
            (model: m, cost: modelCost[m] ?? 0, details: b)
        }.sorted { $0.details.total > $1.details.total }
        let todayProjects = todayProjectMap.map { (p, b) -> ProjectData in
            ProjectData(displayName: ProjectPath.displayName(p), originalName: p, cost: todayProjectCost[p] ?? 0, details: b)
        }.sorted { $0.details.total > $1.details.total }
        let todayModels = todayModelMap.map { (m, b) -> (model: String, cost: Double, details: TokenBreakdown) in
            (model: m, cost: todayModelCost[m] ?? 0, details: b)
        }.sorted { $0.details.total > $1.details.total }

        let monthCost = monthlyCost[currentMonth] ?? 0
        let totCost = monthlyCost.values.reduce(0, +)
        let todayBdSnapshot = todayBd  // Swift 6: 闭包不能捕获 var

        await MainActor.run {
            self.allEntries = entries
            self.dailyData = daily
            self.monthlyData = monthly
            self.projectData = projects
            self.modelData = models
            self.todayProjectData = todayProjects
            self.todayModelData = todayModels
            self.todayBreakdown = todayBdSnapshot
            self.currentMonthCost = monthCost
            self.totalCost = totCost
            self.lastUpdate = Date()
            self.isLoading = false

            umLogger.info("Published: \(daily.count) days, \(monthly.count) months, \(projects.count) projects, \(models.count) models")
        }
    }

    // MARK: - Helper Methods

    /// 优先用日志里的 `costUSD`；若缺失（旧版 Claude Code 日志可能没有），
    /// 按 entry 自己的 model 单价估算。绝不能用合并 breakdown × 单一单价 ——
    /// 多模型混合会算错。
    private func entryCost(_ e: UsageEntry) -> Double {
        e.costUSD > 0 ? e.costUSD : PricingManager.calculateCost(
            input: e.inputTokens,
            cacheCreation: e.cacheCreationTokens,
            cacheRead: e.cacheReadTokens,
            output: e.outputTokens,
            model: e.model
        )
    }

    private func getClaudePaths() -> [URL] {
        var paths: [URL] = []
        let homeDir = FileManager.default.homeDirectoryForCurrentUser

        // XDG config directory (primary, like ccusage)
        if let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            let xdgPath = URL(fileURLWithPath: xdgConfig).appendingPathComponent("claude")
            if FileManager.default.fileExists(atPath: xdgPath.appendingPathComponent("projects").path) {
                paths.append(xdgPath)
            }
        } else {
            let defaultXdgPath = homeDir.appendingPathComponent(".config/claude")
            if FileManager.default.fileExists(atPath: defaultXdgPath.appendingPathComponent("projects").path) {
                paths.append(defaultXdgPath)
            }
        }

        // Legacy ~/.claude directory
        let legacyPath = homeDir.appendingPathComponent(".claude")
        if FileManager.default.fileExists(atPath: legacyPath.appendingPathComponent("projects").path) {
            if !paths.contains(where: { $0.path == legacyPath.path }) {
                paths.append(legacyPath)
            }
        }

        return paths
    }

    /// 从 .../projects/{name}/... 路径里抽出 project 段。
    /// 用 lastIndex 避免家目录路径里就含 "projects" 子段时取错。
    /// e.g. /Users/x/projects/.config/claude/projects/foo/bar.jsonl → "foo"
    private func extractProjectName(from fileURL: URL) -> String {
        let parts = fileURL.pathComponents
        if let idx = parts.lastIndex(of: "projects"), idx + 1 < parts.count {
            return parts[idx + 1]
        }
        return "unknown"
    }

    /// Format timestamp to YYYY-MM-DD using ccusage's approach
    private func formatDateFromTimestamp(_ timestamp: String) -> String {
        if let date = iso8601Formatter.date(from: timestamp) {
            return dayFormatter.string(from: date)
        }

        for parser in fallbackParsers {
            if let date = parser.date(from: timestamp) {
                return dayFormatter.string(from: date)
            }
        }

        // Fallback: take first 10 chars (YYYY-MM-DD)
        return String(timestamp.prefix(10))
    }

    private func getCurrentMonthKey() -> String {
        monthFormatter.string(from: Date())
    }

    private func getCurrentDateKey() -> String {
        dayFormatter.string(from: Date())
    }

    // MARK: - Filter by Month

    func getDailyData(forMonth month: String?) -> [(date: String, tokens: Int)] {
        let data: [(date: String, tokens: Int)]
        if let month = month {
            data = dailyData.filter { $0.date.hasPrefix(month) }
        } else {
            data = dailyData
        }
        return data.sorted { $0.date < $1.date }
    }

    func getProjectData(forMonth month: String?) -> [ProjectData] {
        guard let month = month else {
            return projectData
        }

        let filteredEntries = allEntries.filter { $0.month == month }

        var projectMap: [String: TokenBreakdown] = [:]
        var projectCostMap: [String: Double] = [:]

        for entry in filteredEntries {
            var breakdown = projectMap[entry.project] ?? TokenBreakdown()
            breakdown.input += entry.inputTokens
            breakdown.output += entry.outputTokens
            breakdown.cacheCreation += entry.cacheCreationTokens
            breakdown.cacheRead += entry.cacheReadTokens
            projectMap[entry.project] = breakdown
            projectCostMap[entry.project, default: 0] += entryCost(entry)
        }

        return projectMap.map { (project, breakdown) in
            ProjectData(
                displayName: ProjectPath.displayName(project),
                originalName: project,
                cost: projectCostMap[project] ?? 0,
                details: breakdown
            )
        }.sorted { $0.details.total > $1.details.total }
    }

    func getModelData(forMonth month: String?) -> [(model: String, cost: Double, details: TokenBreakdown)] {
        guard let month = month else {
            return modelData
        }

        let filteredEntries = allEntries.filter { $0.month == month }

        var modelMap: [String: TokenBreakdown] = [:]
        var modelCostMap: [String: Double] = [:]

        for entry in filteredEntries {
            var breakdown = modelMap[entry.model] ?? TokenBreakdown()
            breakdown.input += entry.inputTokens
            breakdown.output += entry.outputTokens
            breakdown.cacheCreation += entry.cacheCreationTokens
            breakdown.cacheRead += entry.cacheReadTokens
            modelMap[entry.model] = breakdown
            modelCostMap[entry.model, default: 0] += entryCost(entry)
        }

        return modelMap.map { (model, breakdown) -> (model: String, cost: Double, details: TokenBreakdown) in
            (model: model, cost: modelCostMap[model] ?? 0, details: breakdown)
        }.sorted { ($0.details.total) > ($1.details.total) }
    }

    func getBreakdown(forMonth month: String?) -> TokenBreakdown {
        guard let month = month else {
            return monthlyData.reduce(TokenBreakdown()) { result, item in
                var r = result
                r.input += item.details.input
                r.output += item.details.output
                r.cacheCreation += item.details.cacheCreation
                r.cacheRead += item.details.cacheRead
                return r
            }
        }

        if let data = monthlyData.first(where: { $0.month == month }) {
            return data.details
        }
        return TokenBreakdown()
    }
}
