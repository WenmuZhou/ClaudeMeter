import Foundation
import os.log

/// 全 app 统一的日志 subsystem。优先用运行时 bundleId（让 fork / rename 自动生效），
/// 兜底用编译期常量保证总是非空。
enum Logging {
    static let subsystem: String = Bundle.main.bundleIdentifier ?? "com.personal.ClaudeMeter"

    /// 工厂方法。用法：`Logging.logger("ModuleName")`
    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
