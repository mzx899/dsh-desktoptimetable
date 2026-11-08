import Foundation

/// 应用数据目录与旧版数据的迁移。
enum AppPaths {
    /// 正式数据目录：`~/Library/Application Support/DesktopTimetable`
    ///
    /// 测试时可以用 `DT_DATA_DIR` 指向临时目录 —— 这样能在**不碰用户真实课表**
    /// 的前提下跑完整的启动 / 渲染 / 迁移链路。
    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["DT_DATA_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DesktopTimetable", isDirectory: true)
    }

    /// 早期版本（课表设置.app + Übersicht widget）用的目录，用于一次性迁移。
    static let legacyDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/timetable", isDirectory: true)

    static var coursesFile: URL { supportDirectory.appendingPathComponent("schedule_data.json") }
    static var semesterFile: URL { supportDirectory.appendingPathComponent("semester.json") }
    static var configFile: URL { supportDirectory.appendingPathComponent("config.json") }

    /// 确保数据目录存在。
    @discardableResult
    static func ensureSupportDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(at: supportDirectory,
                                                    withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// 首次运行时把旧版 `~/.config/timetable` 里的数据搬过来。
    ///
    /// 只在目标文件不存在时复制，不覆盖用户已有数据。
    @discardableResult
    static func migrateLegacyDataIfNeeded() -> Bool {
        ensureSupportDirectory()
        guard FileManager.default.fileExists(atPath: legacyDirectory.path) else { return false }

        var migrated = false
        let pairs: [(URL, URL)] = [
            (legacyDirectory.appendingPathComponent("schedule_data.json"), coursesFile),
            (legacyDirectory.appendingPathComponent("semester.json"), semesterFile),
            (legacyDirectory.appendingPathComponent("config.json"), configFile),
        ]
        for (src, dst) in pairs {
            let dstExists = FileManager.default.fileExists(atPath: dst.path)
            let srcExists = FileManager.default.fileExists(atPath: src.path)
            if srcExists && !dstExists {
                try? FileManager.default.copyItem(at: src, to: dst)
                migrated = true
            }
        }
        return migrated
    }
}
