//
//  ClaudeUsageManager.swift
//  Claude Usage Tracker
//
//  Copyright © 2025 Sergio Bañuls. All rights reserved.
//  Licensed under Personal Use License (Non-Commercial)
//
//  Refactored to match ccusage data extraction logic
//

import Foundation
import Combine

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
    @Published var dataSource: DataSource = .local

    // Available months for filtering
    var availableMonths: [String] {
        monthlyData.map { $0.month }.sorted(by: >)
    }

    enum DataSource {
        case api
        case local
    }

    // MARK: - Data Structures

    struct ProjectData {
        let displayName: String    // 简化后的名称，用于显示
        let originalName: String   // 原始名称，用于计算完整路径
        let cost: Double
        let details: TokenBreakdown
    }

    var onDataUpdated: (() -> Void)?
    var onLoadingStateChanged: ((Bool) -> Void)?

    // MARK: - Token Breakdown

    struct TokenBreakdown {
        var input: Int = 0
        var cacheCreation: Int = 0
        var cacheRead: Int = 0
        var output: Int = 0
        var total: Int { input + output + cacheCreation + cacheRead }
    }

    // MARK: - Usage Entry (Internal)

    private struct UsageEntry {
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
        let uniqueHash: String? // messageId:requestId for deduplication
    }

    // MARK: - Private Properties

    private let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // Cache for file modification dates
    private var fileModificationCache: [String: Date] = [:]
    private var fileResultsCache: [String: [UsageEntry]] = [:]

    // Store all entries for filtering
    private var allEntries: [UsageEntry] = []

    // MARK: - Public Methods

    init() {
        // No initialization required
    }

    func loadData(showLoading: Bool = true) {
        if showLoading {
            self.isLoading = true
            self.onLoadingStateChanged?(true)
        }
        loadLocalData()
    }

    // MARK: - Data Loading

    private func loadLocalData() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Clear cache for fresh data
            self.fileModificationCache.removeAll()
            self.fileResultsCache.removeAll()

            print("[UsageManager] Starting data load from Claude directories")

            // Get all Claude data directories (XDG + legacy)
            let claudePaths = self.getClaudePaths()
            print("[UsageManager] Claude directories: \(claudePaths)")

            // Collect all JSONL files recursively (including subagents subdirectories)
            var allFiles: [(project: String, file: URL)] = []
            for claudePath in claudePaths {
                let projectsPath = claudePath.appendingPathComponent("projects")
                guard let projects = try? FileManager.default.contentsOfDirectory(atPath: projectsPath.path) else {
                    continue
                }
                for project in projects {
                    let projectPath = projectsPath.appendingPathComponent(project)
                    // Recursively find all .jsonl files in project directory
                    if let enumerator = FileManager.default.enumerator(at: projectPath, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for case let fileURL as URL in enumerator {
                            if fileURL.pathExtension == "jsonl" {
                                allFiles.append((project: project, file: fileURL))
                            }
                        }
                    }
                }
            }

            print("[UsageManager] Found \(allFiles.count) JSONL files")

            if allFiles.isEmpty {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.onLoadingStateChanged?(false)
                }
                return
            }

            // Track processed hashes for deduplication (global across all files)
            var processedHashes = Set<String>()
            var allEntries: [UsageEntry] = []

            // Process each file
            for (projectName, filePath) in allFiles {
                let entries = self.processJSONLFile(
                    filePath: filePath,
                    project: projectName,
                    processedHashes: &processedHashes
                )
                allEntries.append(contentsOf: entries)
            }

            print("[UsageManager] Total entries after deduplication: \(allEntries.count)")

            // Store all entries for filtering
            self.allEntries = allEntries

            // Aggregate data
            self.aggregateData(entries: allEntries)
        }
    }

    // MARK: - File Processing

    private func processJSONLFile(
        filePath: URL,
        project: String,
        processedHashes: inout Set<String>
    ) -> [UsageEntry] {
        let fileKey = filePath.path

        // Check cache
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileKey),
           let modDate = attributes[.modificationDate] as? Date {
            if let cachedDate = fileModificationCache[fileKey],
               let cachedResult = fileResultsCache[fileKey],
               modDate <= cachedDate {
                // File unchanged, but still need to check against global processedHashes
                var newEntries: [UsageEntry] = []
                for entry in cachedResult {
                    if let hash = entry.uniqueHash {
                        if !processedHashes.contains(hash) {
                            processedHashes.insert(hash)
                            newEntries.append(entry)
                        }
                    } else {
                        newEntries.append(entry)
                    }
                }
                return newEntries
            }
            fileModificationCache[fileKey] = modDate
        }

        guard let content = try? String(contentsOf: filePath) else { return [] }
        let lines = content.components(separatedBy: .newlines)

        var entries: [UsageEntry] = []

        // First pass: collect last entry per unique message.id (ccusage dedup logic)
        // When requestId is not available, use only message.id for deduplication
        // Key: message.id, Value: (entry, lineNumber)
        var lastEntryForMessageId: [String: (entry: UsageEntry, lineNumber: Int)] = [:]
        var lineNumber = 0

        for line in lines where !line.isEmpty {
            lineNumber += 1
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Parse the entry
            guard let entry = parseUsageEntry(json: json, project: project) else {
                continue
            }

            // Deduplication logic (matching ccusage):
            // - If message.id exists, keep the last entry for each message.id
            // - If message.id is nil, include all entries (no dedup)
            if let messageId = entry.uniqueHash {
                // Has message.id - keep only the last one
                if let existing = lastEntryForMessageId[messageId] {
                    // Replace if this is a later entry (more complete due to streaming)
                    if lineNumber > existing.lineNumber {
                        lastEntryForMessageId[messageId] = (entry: entry, lineNumber: lineNumber)
                    }
                } else {
                    lastEntryForMessageId[messageId] = (entry: entry, lineNumber: lineNumber)
                }
            } else {
                // No message.id - include directly (no dedup)
                entries.append(entry)
            }
        }

        // Add deduplicated entries that haven't been processed globally
        for (messageId, tuple) in lastEntryForMessageId {
            if !processedHashes.contains(messageId) {
                processedHashes.insert(messageId)
                entries.append(tuple.entry)
            }
        }

        // Cache results
        fileResultsCache[fileKey] = entries

        return entries
    }

    private func parseUsageEntry(json: [String: Any], project: String) -> UsageEntry? {
        // Extract timestamp
        guard let timestamp = json["timestamp"] as? String else {
            return nil
        }

        // Extract message
        guard let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return nil
        }

        // Extract usage tokens
        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let cacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0

        // Skip entries with no usage data
        if inputTokens == 0 && outputTokens == 0 && cacheCreationTokens == 0 && cacheReadTokens == 0 {
            return nil
        }

        // Extract model name (inside message object, like ccusage)
        var model = message["model"] as? String ?? "unknown"

        // Check for fast mode (ccusage logic)
        if let speed = usage["speed"] as? String, speed == "fast" {
            model = "\(model)-fast"
        }

        // Extract cost (prefer costUSD, like ccusage in 'auto' mode)
        let costUSD = json["costUSD"] as? Double ?? 0.0

        // Extract message ID and request ID for deduplication (ccusage logic)
        // ccusage only deduplicates when BOTH messageId AND requestId are present
        // If either is null, the entry is NOT deduplicated
        let messageId = message["id"] as? String
        let requestId = json["requestId"] as? String

        // Create unique hash only if both are present and non-empty (matching ccusage)
        let uniqueHash: String?
        if let messageId = messageId, !messageId.isEmpty,
           let requestId = requestId, !requestId.isEmpty {
            uniqueHash = "\(messageId):\(requestId)"
        } else {
            // If either is missing/null, no deduplication (per ccusage logic)
            uniqueHash = nil
        }

        // Format date using ccusage's formatDate logic
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

    // MARK: - Data Aggregation

    private func aggregateData(entries: [UsageEntry]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            print("[UsageManager] Aggregating \(entries.count) entries")

            // Get today's date string
            let todayStr = self.getCurrentDateKey()

            // Aggregate by date (daily data)
            var dailyMap: [String: Int] = [:]
            for entry in entries {
                let totalTokens = entry.inputTokens + entry.outputTokens + entry.cacheCreationTokens + entry.cacheReadTokens
                dailyMap[entry.date, default: 0] += totalTokens
            }

            // Aggregate by month
            var monthlyMap: [String: TokenBreakdown] = [:]
            var monthlyCostMap: [String: Double] = [:]
            for entry in entries {
                var breakdown = monthlyMap[entry.month] ?? TokenBreakdown()
                breakdown.input += entry.inputTokens
                breakdown.output += entry.outputTokens
                breakdown.cacheCreation += entry.cacheCreationTokens
                breakdown.cacheRead += entry.cacheReadTokens
                monthlyMap[entry.month] = breakdown
                monthlyCostMap[entry.month, default: 0] += entry.costUSD
            }

            // Aggregate by project (all time)
            var projectMap: [String: TokenBreakdown] = [:]
            var projectCostMap: [String: Double] = [:]
            for entry in entries {
                var breakdown = projectMap[entry.project] ?? TokenBreakdown()
                breakdown.input += entry.inputTokens
                breakdown.output += entry.outputTokens
                breakdown.cacheCreation += entry.cacheCreationTokens
                breakdown.cacheRead += entry.cacheReadTokens
                projectMap[entry.project] = breakdown
                projectCostMap[entry.project, default: 0] += entry.costUSD
            }

            // Aggregate by model (all time)
            var modelMap: [String: TokenBreakdown] = [:]
            var modelCostMap: [String: Double] = [:]
            for entry in entries {
                var breakdown = modelMap[entry.model] ?? TokenBreakdown()
                breakdown.input += entry.inputTokens
                breakdown.output += entry.outputTokens
                breakdown.cacheCreation += entry.cacheCreationTokens
                breakdown.cacheRead += entry.cacheReadTokens
                modelMap[entry.model] = breakdown
                modelCostMap[entry.model, default: 0] += entry.costUSD
            }

            // Aggregate today's projects
            var todayProjectMap: [String: TokenBreakdown] = [:]
            var todayProjectCostMap: [String: Double] = [:]
            var todayBreakdown = TokenBreakdown()
            for entry in entries where entry.date == todayStr {
                var breakdown = todayProjectMap[entry.project] ?? TokenBreakdown()
                breakdown.input += entry.inputTokens
                breakdown.output += entry.outputTokens
                breakdown.cacheCreation += entry.cacheCreationTokens
                breakdown.cacheRead += entry.cacheReadTokens
                todayProjectMap[entry.project] = breakdown
                todayProjectCostMap[entry.project, default: 0] += entry.costUSD

                todayBreakdown.input += entry.inputTokens
                todayBreakdown.output += entry.outputTokens
                todayBreakdown.cacheCreation += entry.cacheCreationTokens
                todayBreakdown.cacheRead += entry.cacheReadTokens
            }

            // Aggregate today's models
            var todayModelMap: [String: TokenBreakdown] = [:]
            var todayModelCostMap: [String: Double] = [:]
            for entry in entries where entry.date == todayStr {
                var breakdown = todayModelMap[entry.model] ?? TokenBreakdown()
                breakdown.input += entry.inputTokens
                breakdown.output += entry.outputTokens
                breakdown.cacheCreation += entry.cacheCreationTokens
                breakdown.cacheRead += entry.cacheReadTokens
                todayModelMap[entry.model] = breakdown
                todayModelCostMap[entry.model, default: 0] += entry.costUSD
            }

            // Convert to published arrays
            self.dailyData = dailyMap.map { (date, tokens) in
                (date: date, tokens: tokens)
            }.sorted { $0.date < $1.date }

            self.monthlyData = monthlyMap.map { (month, breakdown) in
                let cost = monthlyCostMap[month] ?? self.calculateCost(breakdown)
                return (month: month, cost: cost, details: breakdown)
            }.sorted { $0.month > $1.month }

            self.projectData = projectMap.map { (project, breakdown) in
                let cost = projectCostMap[project] ?? self.calculateCost(breakdown)
                return ProjectData(
                    displayName: self.simplifyProjectName(project),
                    originalName: project,
                    cost: cost,
                    details: breakdown
                )
            }.sorted { $0.details.total > $1.details.total }

            self.modelData = modelMap.map { (model, breakdown) -> (model: String, cost: Double, details: TokenBreakdown) in
                let cost = modelCostMap[model] ?? self.calculateCost(breakdown)
                return (model: model, cost: cost, details: breakdown)
            }.sorted { ($0.details.total) > ($1.details.total) }

            // Today's data
            self.todayProjectData = todayProjectMap.map { (project, breakdown) in
                let cost = todayProjectCostMap[project] ?? self.calculateCost(breakdown)
                return ProjectData(
                    displayName: self.simplifyProjectName(project),
                    originalName: project,
                    cost: cost,
                    details: breakdown
                )
            }.sorted { $0.details.total > $1.details.total }

            self.todayModelData = todayModelMap.map { (model, breakdown) -> (model: String, cost: Double, details: TokenBreakdown) in
                let cost = todayModelCostMap[model] ?? self.calculateCost(breakdown)
                return (model: model, cost: cost, details: breakdown)
            }.sorted { ($0.details.total) > ($1.details.total) }

            self.todayBreakdown = todayBreakdown

            // Calculate totals
            let currentMonth = self.getCurrentMonthKey()
            self.currentMonthCost = self.monthlyData.first(where: { $0.month == currentMonth })?.cost ?? 0.0
            self.totalCost = self.monthlyData.reduce(0) { $0 + $1.cost }

            self.dataSource = .local
            self.lastUpdate = Date()
            self.isLoading = false
            self.onLoadingStateChanged?(false)
            self.onDataUpdated?()

            print("[UsageManager] Aggregation complete:")
            print("  - Daily data: \(self.dailyData.count) days")
            print("  - Monthly data: \(self.monthlyData.count) months")
            print("  - Project data: \(self.projectData.count) projects")
            print("  - Model data: \(self.modelData.count) models")
            print("  - Today projects: \(self.todayProjectData.count)")
            print("  - Today models: \(self.todayModelData.count)")
            print("  - Total cost: $\(String(format: "%.4f", self.totalCost))")
        }
    }

    // MARK: - Helper Methods

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
            // Default XDG path
            let defaultXdgPath = homeDir.appendingPathComponent(".config/claude")
            if FileManager.default.fileExists(atPath: defaultXdgPath.appendingPathComponent("projects").path) {
                paths.append(defaultXdgPath)
            }
        }

        // Legacy ~/.claude directory
        let legacyPath = homeDir.appendingPathComponent(".claude")
        if FileManager.default.fileExists(atPath: legacyPath.appendingPathComponent("projects").path) {
            // Avoid duplicates
            if !paths.contains(where: { $0.path == legacyPath.path }) {
                paths.append(legacyPath)
            }
        }

        return paths
    }

    /// Format timestamp to YYYY-MM-DD using ccusage's approach
    /// Uses Intl.DateTimeFormat equivalent in Swift
    private func formatDateFromTimestamp(_ timestamp: String) -> String {
        // Try ISO8601 first
        if let date = iso8601Formatter.date(from: timestamp) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_CA") // en-CA gives YYYY-MM-DD format
            return formatter.string(from: date)
        }

        // Try parsing with DateFormatter for various formats
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd"
        ]

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: timestamp) {
                let outputFormatter = DateFormatter()
                outputFormatter.dateFormat = "yyyy-MM-dd"
                outputFormatter.locale = Locale(identifier: "en_CA")
                return outputFormatter.string(from: date)
            }
        }

        // Fallback: extract first 10 characters (YYYY-MM-DD)
        return String(timestamp.prefix(10))
    }

    private func calculateCost(_ breakdown: TokenBreakdown) -> Double {
        // Use pricing manager for cost calculation
        let pricing = PricingManager.getPricing(for: "claude-sonnet-4-6")
        let inputCost = Double(breakdown.input) * pricing.inputPrice / 1_000_000
        let cacheCreationCost = Double(breakdown.cacheCreation) * pricing.cacheCreation / 1_000_000
        let cacheReadCost = Double(breakdown.cacheRead) * pricing.cacheRead / 1_000_000
        let outputCost = Double(breakdown.output) * pricing.outputPrice / 1_000_000
        return inputCost + cacheCreationCost + cacheReadCost + outputCost
    }

    private func getCurrentMonthKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    private func getCurrentDateKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func simplifyProjectName(_ projectName: String) -> String {
        if projectName.isEmpty || projectName == "unknown" {
            return "Unknown Project"
        }

        if !projectName.hasPrefix("-Users-") {
            return projectName
        }

        // 1. 先把连续的 - 替换成单个 -
        var path = projectName
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
        return parts.last ?? projectName
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
            projectCostMap[entry.project, default: 0] += entry.costUSD
        }

        return projectMap.map { (project, breakdown) in
            let cost = projectCostMap[project] ?? self.calculateCost(breakdown)
            return ProjectData(
                displayName: self.simplifyProjectName(project),
                originalName: project,
                cost: cost,
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
            modelCostMap[entry.model, default: 0] += entry.costUSD
        }

        return modelMap.map { (model, breakdown) -> (model: String, cost: Double, details: TokenBreakdown) in
            let cost = modelCostMap[model] ?? self.calculateCost(breakdown)
            return (model: model, cost: cost, details: breakdown)
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
