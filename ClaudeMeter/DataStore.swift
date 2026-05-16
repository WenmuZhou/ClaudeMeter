import SwiftData
import Foundation

// MARK: - SwiftData Models

@Model
final class DailySummary {
    @Attribute(.unique) var date: String    // 2026-05-16
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var costUSD: Double

    init(date: String, inputTokens: Int = 0, outputTokens: Int = 0,
         cacheCreationTokens: Int = 0, cacheReadTokens: Int = 0, costUSD: Double = 0.0) {
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.costUSD = costUSD
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }
}

@Model
final class MonthlySummary {
    @Attribute(.unique) var month: String   // 2026-05
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var costUSD: Double

    init(month: String, inputTokens: Int = 0, outputTokens: Int = 0,
         cacheCreationTokens: Int = 0, cacheReadTokens: Int = 0, costUSD: Double = 0.0) {
        self.month = month
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.costUSD = costUSD
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }
}

@Model
final class ProjectSummary {
    var month: String       // 2026-05
    var project: String     // 原始项目名
    var displayName: String // 简化后的显示名
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var costUSD: Double

    init(month: String, project: String, displayName: String,
         inputTokens: Int = 0, outputTokens: Int = 0,
         cacheCreationTokens: Int = 0, cacheReadTokens: Int = 0, costUSD: Double = 0.0) {
        self.month = month
        self.project = project
        self.displayName = displayName
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.costUSD = costUSD
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }
}

@Model
final class ModelSummary {
    var month: String       // 2026-05
    var model: String       // 模型名
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var costUSD: Double

    init(month: String, model: String,
         inputTokens: Int = 0, outputTokens: Int = 0,
         cacheCreationTokens: Int = 0, cacheReadTokens: Int = 0, costUSD: Double = 0.0) {
        self.month = month
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.costUSD = costUSD
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }
}

// MARK: - DataStore Actor

@ModelActor
actor DataStore {
    // MARK: - Read Operations

    func fetchAllDailySummaries() -> [DailySummary] {
        let descriptor = FetchDescriptor<DailySummary>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func fetchAllMonthlySummaries() -> [MonthlySummary] {
        let descriptor = FetchDescriptor<MonthlySummary>(
            sortBy: [SortDescriptor(\.month, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func fetchAllProjectSummaries() -> [ProjectSummary] {
        let descriptor = FetchDescriptor<ProjectSummary>(
            sortBy: [SortDescriptor(\.month, order: .reverse), SortDescriptor(\.project)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func fetchAllModelSummaries() -> [ModelSummary] {
        let descriptor = FetchDescriptor<ModelSummary>(
            sortBy: [SortDescriptor(\.month, order: .reverse), SortDescriptor(\.model)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Update Operations

    /// 增量更新：添加新的条目到数据库
    func upsertEntries(_ entries: [UsageEntry]) {
        for entry in entries {
            // 更新每日汇总
            upsertDailySummary(entry: entry)

            // 更新每月汇总
            upsertMonthlySummary(entry: entry)

            // 更新项目汇总
            upsertProjectSummary(entry: entry)

            // 更新模型汇总
            upsertModelSummary(entry: entry)
        }

        try? modelContext.save()
    }

    private func upsertDailySummary(entry: UsageEntry) {
        let entryDate = entry.date
        let predicate = #Predicate<DailySummary> { $0.date == entryDate }
        let descriptor = FetchDescriptor<DailySummary>(predicate: predicate)

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.inputTokens += entry.inputTokens
            existing.outputTokens += entry.outputTokens
            existing.cacheCreationTokens += entry.cacheCreationTokens
            existing.cacheReadTokens += entry.cacheReadTokens
            existing.costUSD += entry.costUSD
        } else {
            let summary = DailySummary(
                date: entry.date,
                inputTokens: entry.inputTokens,
                outputTokens: entry.outputTokens,
                cacheCreationTokens: entry.cacheCreationTokens,
                cacheReadTokens: entry.cacheReadTokens,
                costUSD: entry.costUSD
            )
            modelContext.insert(summary)
        }
    }

    private func upsertMonthlySummary(entry: UsageEntry) {
        let entryMonth = entry.month
        let predicate = #Predicate<MonthlySummary> { $0.month == entryMonth }
        let descriptor = FetchDescriptor<MonthlySummary>(predicate: predicate)

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.inputTokens += entry.inputTokens
            existing.outputTokens += entry.outputTokens
            existing.cacheCreationTokens += entry.cacheCreationTokens
            existing.cacheReadTokens += entry.cacheReadTokens
            existing.costUSD += entry.costUSD
        } else {
            let summary = MonthlySummary(
                month: entry.month,
                inputTokens: entry.inputTokens,
                outputTokens: entry.outputTokens,
                cacheCreationTokens: entry.cacheCreationTokens,
                cacheReadTokens: entry.cacheReadTokens,
                costUSD: entry.costUSD
            )
            modelContext.insert(summary)
        }
    }

    private func upsertProjectSummary(entry: UsageEntry) {
        let displayName = simplifyProjectName(entry.project)
        let entryMonth = entry.month
        let entryProject = entry.project
        let predicate = #Predicate<ProjectSummary> {
            $0.month == entryMonth && $0.project == entryProject
        }
        let descriptor = FetchDescriptor<ProjectSummary>(predicate: predicate)

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.inputTokens += entry.inputTokens
            existing.outputTokens += entry.outputTokens
            existing.cacheCreationTokens += entry.cacheCreationTokens
            existing.cacheReadTokens += entry.cacheReadTokens
            existing.costUSD += entry.costUSD
        } else {
            let summary = ProjectSummary(
                month: entry.month,
                project: entry.project,
                displayName: displayName,
                inputTokens: entry.inputTokens,
                outputTokens: entry.outputTokens,
                cacheCreationTokens: entry.cacheCreationTokens,
                cacheReadTokens: entry.cacheReadTokens,
                costUSD: entry.costUSD
            )
            modelContext.insert(summary)
        }
    }

    private func upsertModelSummary(entry: UsageEntry) {
        let entryMonth = entry.month
        let entryModel = entry.model
        let predicate = #Predicate<ModelSummary> {
            $0.month == entryMonth && $0.model == entryModel
        }
        let descriptor = FetchDescriptor<ModelSummary>(predicate: predicate)

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.inputTokens += entry.inputTokens
            existing.outputTokens += entry.outputTokens
            existing.cacheCreationTokens += entry.cacheCreationTokens
            existing.cacheReadTokens += entry.cacheReadTokens
            existing.costUSD += entry.costUSD
        } else {
            let summary = ModelSummary(
                month: entry.month,
                model: entry.model,
                inputTokens: entry.inputTokens,
                outputTokens: entry.outputTokens,
                cacheCreationTokens: entry.cacheCreationTokens,
                cacheReadTokens: entry.cacheReadTokens,
                costUSD: entry.costUSD
            )
            modelContext.insert(summary)
        }
    }

    // MARK: - Helper Methods

    private func simplifyProjectName(_ projectName: String) -> String {
        if projectName.isEmpty || projectName == "unknown" {
            return "Unknown Project"
        }

        if !projectName.hasPrefix("-Users-") {
            return projectName
        }

        var path = projectName
        while path.contains("--") {
            path = path.replacingOccurrences(of: "--", with: "-")
        }
        path = path.replacingOccurrences(of: "-", with: "/")

        if path.hasPrefix("/") {
            path = String(path.dropFirst())
        }

        let parts = path.components(separatedBy: "/").filter { !$0.isEmpty }
        return parts.last ?? projectName
    }
}

// MARK: - Global DataStore Accessor

private let _dataStoreContainer: ModelContainer = {
    try! ModelContainer(
        for: DailySummary.self, MonthlySummary.self, ProjectSummary.self, ModelSummary.self,
        configurations: ModelConfiguration(
            "ClaudeMeter",
            isStoredInMemoryOnly: false
        )
    )
}()

var sharedDataStore: DataStore {
    DataStore(modelContainer: _dataStoreContainer)
}
