import SwiftData
import Foundation
import os.log

// Swift 6 strict mode 把 static let 也推断成 main-actor isolated，
// 显式 nonisolated 才能在 actor 里访问。Logger 是 Sendable，安全。
private enum DSLog {
    nonisolated(unsafe) static let logger = Logging.logger("DataStore")
}

// MARK: - SwiftData Models

/// 一条原始的 token 用量记录（去重后），是数据库的唯一权威来源。
/// 所有 daily/monthly/project/model 聚合都从这张表实时计算，避免聚合表与原始数据漂移。
@Model
final class RawUsageEntry {
    /// 唯一键：
    /// - 当 messageId/requestId 都存在时：`"id:<messageId>:<requestId>"`
    /// - 否则（ccusage 不去重的场景）：`"loc:<filePath>:<lineNumber>"`
    @Attribute(.unique) var uniqueHash: String

    /// 来源 JSONL 文件路径。文件被重新解析时，按此字段先删后插实现 replace 语义。
    var sourceFilePath: String

    var timestamp: String
    var date: String        // YYYY-MM-DD
    var month: String       // YYYY-MM
    var project: String
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var costUSD: Double

    init(uniqueHash: String, sourceFilePath: String, timestamp: String,
         date: String, month: String, project: String, model: String,
         inputTokens: Int, outputTokens: Int, cacheCreationTokens: Int,
         cacheReadTokens: Int, costUSD: Double) {
        self.uniqueHash = uniqueHash
        self.sourceFilePath = sourceFilePath
        self.timestamp = timestamp
        self.date = date
        self.month = month
        self.project = project
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

/// 文件指纹：用 (size, mtime) 判断 JSONL 是否变化，未变化则跳过整文件。
@Model
final class FileCursor {
    @Attribute(.unique) var filePath: String
    var fileSize: Int64
    var mtime: Date

    init(filePath: String, fileSize: Int64, mtime: Date) {
        self.filePath = filePath
        self.fileSize = fileSize
        self.mtime = mtime
    }
}

// MARK: - DataStore Actor

@ModelActor
actor DataStore {

    // MARK: Read

    /// 读取所有原始 entry，转回 UsageEntry struct 给 UsageManager 做聚合。
    func fetchAllRawEntries() -> [UsageEntry] {
        let descriptor = FetchDescriptor<RawUsageEntry>()
        let raws = (try? modelContext.fetch(descriptor)) ?? []
        return raws.map { raw in
            UsageEntry(
                timestamp: raw.timestamp,
                date: raw.date,
                month: raw.month,
                project: raw.project,
                model: raw.model,
                inputTokens: raw.inputTokens,
                outputTokens: raw.outputTokens,
                cacheCreationTokens: raw.cacheCreationTokens,
                cacheReadTokens: raw.cacheReadTokens,
                costUSD: raw.costUSD,
                uniqueHash: raw.uniqueHash
            )
        }
    }

    /// 查文件指纹。返回 nil 表示从未处理过。
    func fetchCursor(filePath: String) -> (size: Int64, mtime: Date)? {
        let p = filePath
        let descriptor = FetchDescriptor<FileCursor>(
            predicate: #Predicate { $0.filePath == p }
        )
        if let cursor = try? modelContext.fetch(descriptor).first {
            return (cursor.fileSize, cursor.mtime)
        }
        return nil
    }

    // MARK: Write

    /// 用新 entries 替换某个文件原本贡献的所有 entry，并更新 cursor。
    /// 单次 save 内完成，等价于一次事务。
    ///
    /// 性能：先一次性把当前 DB 里的所有 hash 拉到 Set，避免 N+1 的 fetch 查询。
    func replaceEntriesForFile(
        filePath: String,
        newEntries: [UsageEntry],
        fileSize: Int64,
        mtime: Date
    ) {
        let p = filePath

        // 1. 删除该文件旧的 entries
        let oldDescriptor = FetchDescriptor<RawUsageEntry>(
            predicate: #Predicate { $0.sourceFilePath == p }
        )
        let oldEntries = (try? modelContext.fetch(oldDescriptor)) ?? []
        for entry in oldEntries {
            modelContext.delete(entry)
        }

        // 2. 拉一次性的 hash 黑名单：当前 DB 中其它文件占用的 hash。
        //    旧 entries 已经 delete，但同 transaction 下未 save 还能 fetch 到，所以排除掉。
        let oldHashes = Set(oldEntries.map { $0.uniqueHash })
        let allRaws = (try? modelContext.fetch(FetchDescriptor<RawUsageEntry>())) ?? []
        var existingHashes = Set(allRaws.map { $0.uniqueHash })
        existingHashes.subtract(oldHashes)  // 待删的不算占用

        // 3. 插入新 entries
        var inserted = 0
        var skippedDup = 0
        for entry in newEntries {
            guard let h = entry.uniqueHash, !h.isEmpty else { continue }
            if existingHashes.contains(h) {
                skippedDup += 1
                continue
            }
            existingHashes.insert(h)  // 防止本批次内重复
            let raw = RawUsageEntry(
                uniqueHash: h,
                sourceFilePath: filePath,
                timestamp: entry.timestamp,
                date: entry.date,
                month: entry.month,
                project: entry.project,
                model: entry.model,
                inputTokens: entry.inputTokens,
                outputTokens: entry.outputTokens,
                cacheCreationTokens: entry.cacheCreationTokens,
                cacheReadTokens: entry.cacheReadTokens,
                costUSD: entry.costUSD
            )
            modelContext.insert(raw)
            inserted += 1
        }

        // 4. upsert cursor
        let cursorDescriptor = FetchDescriptor<FileCursor>(
            predicate: #Predicate { $0.filePath == p }
        )
        if let existing = try? modelContext.fetch(cursorDescriptor).first {
            existing.fileSize = fileSize
            existing.mtime = mtime
        } else {
            let cursor = FileCursor(filePath: filePath, fileSize: fileSize, mtime: mtime)
            modelContext.insert(cursor)
        }

        do {
            try modelContext.save()
        } catch {
            DSLog.logger.error("Failed to save: \(error.localizedDescription)")
        }

        DSLog.logger.debug("replaced \(filePath, privacy: .public): -\(oldEntries.count) +\(inserted) (\(skippedDup) global dups)")
    }

    /// 清空全部数据（debug / 用户重置用）。
    func clearAll() {
        try? modelContext.delete(model: RawUsageEntry.self)
        try? modelContext.delete(model: FileCursor.self)
        try? modelContext.save()
        DSLog.logger.info("cleared all data")
    }
}

// MARK: - Global DataStore

/// 持久化 ModelContainer。失败时回退到内存模式，避免应用崩溃。
private let _dataStoreContainer: ModelContainer = {
    let schema = Schema([RawUsageEntry.self, FileCursor.self])
    let persistentConfig = ModelConfiguration(
        "ClaudeMeterV2",
        schema: schema,
        isStoredInMemoryOnly: false
    )
    if let container = try? ModelContainer(for: schema, configurations: [persistentConfig]) {
        return container
    }
    DSLog.logger.error("Persistent ModelContainer failed, falling back to in-memory.")
    let memoryConfig = ModelConfiguration(
        "ClaudeMeterV2-mem",
        schema: schema,
        isStoredInMemoryOnly: true
    )
    return try! ModelContainer(for: schema, configurations: [memoryConfig])
}()

/// 真·单例：actor 只创建一次，所有调用走同一个 mailbox。
let sharedDataStore = DataStore(modelContainer: _dataStoreContainer)
