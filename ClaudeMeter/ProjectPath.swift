import Foundation

/// Claude Code 把项目路径编码成目录名（`/` 替换成 `-`），这个工具负责把它解回来。
/// e.g. `-Users-eleme-Desktop-project-ClaudeMeter` ↔ `/Users/eleme/Desktop/project/ClaudeMeter`
enum ProjectPath {

    /// 取目录名最后一段作为简化展示名。
    /// e.g. `-Users-eleme-Desktop-project-ClaudeMeter` → `ClaudeMeter`
    static func displayName(_ projectName: String) -> String {
        if projectName.isEmpty || projectName == "unknown" {
            return "Unknown Project"
        }
        guard projectName.hasPrefix("-Users-") else {
            return projectName
        }
        let parts = decode(projectName).components(separatedBy: "/").filter { !$0.isEmpty }
        return parts.last ?? projectName
    }

    /// 还原成绝对路径用于 tooltip / 二级展示。
    /// e.g. `-Users-eleme-Desktop-project-ClaudeMeter` → `/Users/eleme/Desktop/project/ClaudeMeter`
    static func fullPath(_ projectName: String) -> String {
        guard projectName.hasPrefix("-Users-") else {
            return projectName
        }
        var path = decode(projectName)
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        return path
    }

    /// 内部：连续 `--` 折叠成 `-`，再把 `-` 替换成 `/`。
    /// 注意 Claude 的编码不可逆（原路径里的 `-` 也变成 `/`），这里只是 best effort。
    private static func decode(_ encoded: String) -> String {
        var s = encoded
        while s.contains("--") {
            s = s.replacingOccurrences(of: "--", with: "-")
        }
        s = s.replacingOccurrences(of: "-", with: "/")
        if s.hasPrefix("/") {
            s = String(s.dropFirst())
        }
        return s
    }
}
