import Foundation

/// 课表 / 学期 / 外观配置的读写。
///
/// 目录可注入，方便单元测试用临时目录。
final class ScheduleStore {
    enum StoreError: LocalizedError {
        case encodingFailed
        case writeFailed(String)
        case emptyFile
        case notAnArray
        case invalidCourse(index: Int, reason: String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed: return "数据编码失败"
            case .writeFailed(let m): return "写入失败：\(m)"
            case .emptyFile: return "课表数据文件是空的"
            case .notAnArray: return "课表数据文件的顶层不是数组"
            case .invalidCourse(let i, let r):
                return "第 \(i) 条课程数据无效：\(r)"
            }
        }
    }

    static let defaultConfig: [String: Double] = [
        "fadeInSec": 0.8,     // 变实（鼠标移入）秒数
        "fadeOutSec": 6.0,    // 变虚（鼠标移开）秒数
        "minOpacity": 0.22,   // 静置不透明度：0=全透明，1=不虚化
        "maxOpacity": 1.0,    // 悬停不透明度：0=看不见，1=完全清晰
        "panelOpacity": 1.0,  // 设置面板自身的不透明度
    ]

    let directory: URL
    /// 外观配置（`config.json`）所在目录。
    ///
    /// 阶段 3 引入多课表后，课程数据搬到 `timetables/<uuid>/` 下，
    /// 但外观设置是**全局**的 —— 所有课表共用一份 `config.json`。
    /// 这个属性就是为此存在的：课程目录和配置目录可以不是同一个。
    let configDirectory: URL

    init(directory: URL = AppPaths.supportDirectory, configDirectory: URL? = nil) {
        self.directory = directory
        self.configDirectory = configDirectory ?? directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: 文件路径

    var coursesFile: URL { directory.appendingPathComponent("schedule_data.json") }
    /// 供「在访达中显示」用：数据目录本身
    var dataFileURL: URL { directory }
    var semesterFile: URL { directory.appendingPathComponent("semester.json") }
    var configFile: URL { configDirectory.appendingPathComponent("config.json") }
    /// 备份目录（写盘前自动备份，最多保留 5 份）。
    var backupsDirectory: URL { directory.appendingPathComponent("backups", isDirectory: true) }

    // MARK: 课程

    /// 读取课程。文件不存在返回空数组；文件存在但内容非法时**抛出可读错误**，
    /// 不用空数组糊弄过去。
    func loadCourses() throws -> [Course] {
        guard FileManager.default.fileExists(atPath: coursesFile.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: coursesFile)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
        guard !data.isEmpty else { throw StoreError.emptyFile }

        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw StoreError.notAnArray
        }
        guard let arr = obj as? [Any] else { throw StoreError.notAnArray }

        var out: [Course] = []
        for (i, item) in arr.enumerated() {
            guard let dict = item as? [String: Any] else {
                throw StoreError.invalidCourse(index: i + 1, reason: "不是一条课程记录")
            }
            do {
                out.append(try Course(dictionary: dict))
            } catch let e as Course.DecodeError {
                throw StoreError.invalidCourse(index: i + 1, reason: e.errorDescription ?? "数据无效")
            } catch {
                throw StoreError.invalidCourse(index: i + 1, reason: error.localizedDescription)
            }
        }
        return out
    }

    /// 逐条读取课程：**能读多少读多少**，读不了的记下来。
    ///
    /// 以前 `loadCoursesOrNil()` 是 `try? loadCourses()` ——
    /// 只要有一条记录非法，整个文件就当没读到（返回 nil），上层于是把课表当成
    /// 「空课表」。注释写着「把能读的部分显示出来」，实际做不到。
    ///
    /// - Returns: 读到的课程 + 每条读不了的记录的原因（按出现顺序）。
    func loadCoursesPartial() -> (courses: [Course], failures: [String]) {
        guard let data = try? Data(contentsOf: coursesFile),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let arr = obj as? [Any] else { return ([], []) }
        var out: [Course] = []
        var failures: [String] = []
        for (i, item) in arr.enumerated() {
            guard let dict = item as? [String: Any] else {
                failures.append("第 \(i + 1) 条不是一条课程记录")
                continue
            }
            do {
                out.append(try Course(dictionary: dict))
            } catch let e as Course.DecodeError {
                failures.append("第 \(i + 1) 条：\(e.errorDescription ?? "数据无效")")
            } catch {
                failures.append("第 \(i + 1) 条：\(error.localizedDescription)")
            }
        }
        return (out, failures)
    }

    /// 读取课程；出错时返回 nil（供「尽力而为」的路径使用）。
    ///
    /// 注意：这是**全有或全无**的读取 —— 一条记录非法就整个文件读不出来。
    /// 要「能读多少读多少」用 `loadCoursesPartial()`。
    func loadCoursesOrNil() -> [Course]? {
        try? loadCourses()
    }

    func saveCourses(_ courses: [Course]) throws {
        let data = try JSONEncoder().encode(courses)
        try write(data, to: coursesFile)
    }

    // MARK: 临时覆盖

    /// 临时覆盖数据文件（每份课表目录下独立一份）。
    ///
    /// 独立存放的理由：覆盖是**另一种记录类型**（某个格子在某几周里归一门课），
    /// 混进 `courses` 会被 `CourseGrouper` 按名字合并、会被 `TimetableDiff`
    /// 当成课程做差异匹配，删课程时也会把它一起删掉。
    var overridesFile: URL { directory.appendingPathComponent("week_overrides.json") }

    /// 读取覆盖记录。文件不存在 → 空数组。
    func loadOverrides() throws -> [WeekOverride] {
        guard FileManager.default.fileExists(atPath: overridesFile.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: overridesFile)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
        guard !data.isEmpty else { return [] }
        return try JSONDecoder().decode([WeekOverride].self, from: data)
    }

    /// 逐条读取覆盖记录：**能读多少读多少**，读不了的记下来。
    ///
    /// 覆盖文件坏了**只影响覆盖本身** —— 原课表照常能用（课程数据在另一个文件里）。
    func loadOverridesPartial() -> (overrides: [WeekOverride], failures: [String]) {
        guard let data = try? Data(contentsOf: overridesFile),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let arr = obj as? [Any] else { return ([], []) }
        var out: [WeekOverride] = []
        var failures: [String] = []
        for (i, item) in arr.enumerated() {
            guard let dict = item as? [String: Any],
                  let one = try? JSONSerialization.data(withJSONObject: dict) else {
                failures.append("第 \(i + 1) 条不是一条覆盖记录")
                continue
            }
            do {
                out.append(try JSONDecoder().decode(WeekOverride.self, from: one))
            } catch {
                failures.append("第 \(i + 1) 条：\(error.localizedDescription)")
            }
        }
        return (out, failures)
    }

    func saveOverrides(_ overrides: [WeekOverride]) throws {
        let data = try JSONEncoder().encode(overrides)
        try write(data, to: overridesFile)
    }

    /// 备份覆盖数据到 `backups/`（与课程数据分开命名，互不干扰）。
    @discardableResult
    func backupOverrides(keep: Int = 5) -> URL? {
        guard FileManager.default.fileExists(atPath: overridesFile.path) else { return nil }
        let target = BackupFile.copy(source: overridesFile, into: backupsDirectory,
                                     prefix: "week_overrides-", suffix: ".json")
        pruneOverrideBackups(keep: keep)
        return target
    }

    private func listOverrideBackups() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: backupsDirectory,
                                                     includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.lastPathComponent.hasPrefix("week_overrides-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func pruneOverrideBackups(keep: Int) {
        let fm = FileManager.default
        for old in listOverrideBackups().dropFirst(keep) {
            try? fm.removeItem(at: old)
        }
    }

    // MARK: 备份

    /// 备份课程数据到 `backups/`，只保留最近 `keep` 份。
    @discardableResult
    func backupCourses(keep: Int = 5) -> URL? {
        guard FileManager.default.fileExists(atPath: coursesFile.path) else { return nil }
        let target = BackupFile.copy(source: coursesFile, into: backupsDirectory,
                                     prefix: "schedule_data-", suffix: ".json")
        pruneBackups(keep: keep)
        return target
    }

    /// 备份学期配置到 `backups/`。
    @discardableResult
    func backupSemester(keep: Int = 5) -> URL? {
        guard FileManager.default.fileExists(atPath: semesterFile.path) else { return nil }
        let target = BackupFile.copy(source: semesterFile, into: backupsDirectory,
                                     prefix: "semester-", suffix: ".json")
        pruneSemesterBackups(keep: keep)
        return target
    }

    private func pruneSemesterBackups(keep: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: backupsDirectory,
                                                     includingPropertiesForKeys: nil) else { return }
        let old = items.filter { $0.lastPathComponent.hasPrefix("semester-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .dropFirst(keep)
        for f in old { try? fm.removeItem(at: f) }
    }

    /// 列出备份（新的在前）。
    func listBackups() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: backupsDirectory,
                                                     includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        return items
            .filter { $0.lastPathComponent.hasPrefix("schedule_data-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func pruneBackups(keep: Int) {
        let fm = FileManager.default
        for old in listBackups().dropFirst(keep) {
            try? fm.removeItem(at: old)
        }
    }

    // MARK: 学期配置

    /// 读取学期配置（开学日期 + 学期总周数）。
    func loadSemesterConfig() -> SemesterConfig {
        guard let data = try? Data(contentsOf: semesterFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return SemesterConfig(start: defaultSemesterStart) }
        return SemesterConfig.from(json: obj, defaultStart: defaultSemesterStart)
    }

    /// 学期配置文件**存在但读不出来**（损坏）。
    ///
    /// 以前这个情况是隐形的：`loadSemesterConfig()` 静默退回「今年 9 月 1 日 / 16 周」，
    /// 紧接着 `ScheduleRepository.load` 因为「文件里没有 maxWeek 字段」就把默认值写回去 ——
    /// 用户的学期配置被默认值覆盖，而且**没有任何提示**。
    /// 现在上层能先问一句「文件是不是坏了」，坏的就只提示、不覆盖。
    var semesterConfigIsCorrupt: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: semesterFile.path) else { return false }
        guard let data = try? Data(contentsOf: semesterFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return true }
        // `start` 在，但解析不出日期 → 损坏
        if let s = obj["start"] as? String {
            if ISO8601DateFormatter.dayOnly.date(from: s) == nil { return true }
        } else if obj["start"] != nil {
            return true
        }
        // `maxWeek` 在，但不是数字 → 损坏
        if let raw = obj["maxWeek"], !(raw is NSNumber) { return true }
        return false
    }

    /// 学期配置里是否已经写了 `maxWeek`（旧文件没有这个字段）。
    func semesterHasMaxWeek() -> Bool {
        guard let data = try? Data(contentsOf: semesterFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return obj["maxWeek"] != nil
    }

    func saveSemesterConfig(_ config: SemesterConfig) throws {
        let data = try JSONSerialization.data(withJSONObject: config.jsonObject(),
                                              options: [.prettyPrinted, .sortedKeys])
        try write(data, to: semesterFile)
    }

    /// 读取学期起始日；缺失或损坏时退回 9 月 1 日。
    func loadSemesterStart() -> Date {
        loadSemesterConfig().start
    }

    func saveSemesterStart(_ date: Date) throws {
        var config = loadSemesterConfig()
        config.start = date
        try saveSemesterConfig(config)
    }

    /// 默认学期起始日：当年的 9 月 1 日。
    var defaultSemesterStart: Date {
        let c = WeekMath.calendar
        let year = c.component(.year, from: Date())
        return c.date(from: DateComponents(year: year, month: 9, day: 1)) ?? Date()
    }

    // MARK: 外观配置

    func loadConfig() -> [String: Double] {
        var cfg = Self.defaultConfig
        if let data = try? Data(contentsOf: configFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in obj {
                if let d = v as? Double { cfg[k] = d }
                else if let i = v as? Int { cfg[k] = Double(i) }
            }
        }
        return cfg
    }

    /// 写外观配置。
    ///
    /// **读旧文件 → 合并新键 → 原子写回**，不再整份覆盖。
    ///
    /// 为什么要改：旧版 app 的 `saveConfig` 是整份覆盖，只写它认识的 5 项。
    /// 如果这里也整份覆盖，任何一条旧调用路径都会把文件里**别的东西**抹掉
    /// （将来写进 `config.json` 的新字段就再也活不下来）。
    /// 合并之后，旧路径只会覆盖自己那几项，其他键原样保留。
    func saveConfig(_ config: [String: Double]) throws {
        var merged: [String: Any] = [:]
        if let data = try? Data(contentsOf: configFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            merged = obj
        }
        for (k, v) in config { merged[k] = v }
        let data = try JSONSerialization.data(withJSONObject: merged,
                                              options: [.prettyPrinted, .sortedKeys])
        try write(data, to: configFile)
    }

    /// 设置文件（`settings.json`）所在目录 —— 与外观配置同目录（全局）。
    var settingsDirectory: URL { configDirectory }
    /// 设置文件路径。
    var settingsFile: URL { configDirectory.appendingPathComponent("settings.json") }

    // MARK: -

    private func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }
}

// MARK: -

extension ISO8601DateFormatter {
    /// 只含日期的 ISO 格式（"2026-08-31"）。
    static let dayOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()
}
