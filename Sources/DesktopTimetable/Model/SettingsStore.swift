import Foundation

/// 统一设置层：**所有**设置读写的唯一入口。
///
/// 为什么要有这一层：
///   · `config.json` 是旧版 app 也会读写的文件，旧版一保存就**整份覆盖**，
///     只写它认识的外观 5 项。新设置如果也写进去，一存就没了。
///   · 所以新设置放独立文件 `settings.json`，旧版 app 根本不碰它。
///   · 外观仍写 `config.json`（保持旧版兼容），但改成「读旧文件 → 合并 → 原子写回」，
///     任何旧调用路径都不会误删未知字段。
///
/// 目录结构：
/// ```
/// Application Support/DesktopTimetable/
///   config.json          // 外观（全局，旧版也读）
///   settings.json        // 新功能设置（新版专用）
/// ```
final class SettingsStore {

    /// 外观配置文件所在目录（全局，所有课表共用）。
    let configDirectory: URL
    /// 新设置文件所在目录（与外观同目录，保持全局）。
    let settingsDirectory: URL

    /// 读取时的诊断信息（settings.json 损坏等）。
    private(set) var diagnostics: [String] = []

    init(configDirectory: URL = AppPaths.supportDirectory,
         settingsDirectory: URL? = nil) {
        self.configDirectory = configDirectory
        self.settingsDirectory = settingsDirectory ?? configDirectory
    }

    /// 外观配置文件。
    var configFile: URL { configDirectory.appendingPathComponent("config.json") }
    /// 新设置文件。
    var settingsFile: URL { settingsDirectory.appendingPathComponent("settings.json") }
    /// 备份目录（写盘前备份损坏文件用）。
    var backupsDirectory: URL { configDirectory.appendingPathComponent("backups", isDirectory: true) }

    /// `settings.json` 的格式版本。
    static let currentSchemaVersion = 1

    // MARK: - 读

    /// 读取全部设置：外观来自 `config.json`，新设置来自 `settings.json`。
    func load() -> AppSettings {
        diagnostics = []
        let appearance = AppearanceSettings(dictionary: loadAppearanceDictionary())
        var settings = AppSettings(appearance: appearance)
        settings.reminder = ReminderSettings()
        settings.periods = PeriodSettings()
        settings.notes = NoteSettings()
        settings.pet = PetSettings()
        settings.dayPanel = DayPanelSettings()

        guard let obj = readSettingsObject() else {
            // 文件不存在 → 全部默认值（不是错误）
            if settingsFileExists { diagnostics.append("settings.json 读取失败，已按默认值显示") }
            logDiagnostics()
            return settings
        }

        if let r = obj["reminder"] as? [String: Any] {
            settings.reminder = ReminderSettings(json: r)
        }
        if let p = obj["periods"] as? [String: Any] {
            settings.periods = PeriodSettings(json: p)
        }
        if let n = obj["notes"] as? [String: Any] {
            settings.notes = NoteSettings(json: n)
        }
        if let p = obj["pet"] as? [String: Any] {
            settings.pet = PetSettings(json: p)
        }
        if let d = obj["dayPanel"] as? [String: Any] {
            settings.dayPanel = DayPanelSettings(json: d)
        }
        logDiagnostics()
        return settings
    }

    /// 把诊断信息写进系统日志（`Console.app` 里搜 "DesktopTimetable" 就能看到）。
    ///
    /// 以前 `diagnostics` 只存在内存里、**没有任何消费者** ——
    /// 读到一个坏掉的 settings.json，界面上什么都不显示，日志里也没有痕迹，
    /// 排障时完全无从下手。这里给它一个最轻的消费者：NSLog。
    /// 不新增任何 UI。
    private func logDiagnostics() {
        for line in diagnostics {
            NSLog("[DesktopTimetable] settings: %@", line)
        }
    }

    /// 读外观字典（缺键用默认值，类型非法忽略）。
    private func loadAppearanceDictionary() -> [String: Double] {
        var cfg = ScheduleStore.defaultConfig
        if let data = try? Data(contentsOf: configFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in obj {
                if let d = v as? Double { cfg[k] = d }
                else if let i = v as? Int { cfg[k] = Double(i) }
            }
        }
        return cfg
    }

    /// `settings.json` 是否存在。
    var settingsFileExists: Bool {
        FileManager.default.fileExists(atPath: settingsFile.path)
    }

    /// 读 `settings.json` 的原始字典。文件不存在或损坏 → nil。
    ///
    /// - Parameter recordDiagnostics: 是否把读取失败记进 `diagnostics`。
    ///   写盘前的「要不要备份」判断会再读一次，那次**不要**再记一遍诊断
    ///   （否则同一件事在诊断里出现多次，看的人会以为坏了好几回）。
    private func readSettingsObject(recordDiagnostics: Bool = true) -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsFile) else {
            if recordDiagnostics && settingsFileExists {
                diagnostics.append("settings.json 无法读取")
            }
            return nil
        }
        if data.isEmpty {
            if recordDiagnostics {
                diagnostics.append("settings.json 是空文件，已按默认值显示")
            }
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if recordDiagnostics {
                diagnostics.append("settings.json 已损坏，已按默认值显示")
            }
            return nil
        }
        return obj
    }

    /// `settings.json` 是否损坏（存在但读不出来）。
    var settingsFileIsCorrupt: Bool {
        guard settingsFileExists else { return false }
        return readSettingsObject(recordDiagnostics: false) == nil
    }

    // MARK: - 写

    /// 保存全部设置：外观写 `config.json`，新设置写 `settings.json`。
    func save(_ settings: AppSettings) throws {
        try saveAppearance(settings.appearance)
        try saveNewSettings(settings)
    }

    /// 只写外观（`config.json`）。
    ///
    /// **读旧文件 → 合并新键 → 原子写回** —— 不整份覆盖，
    /// 免得旧调用路径把别人写的字段抹掉。
    func saveAppearance(_ appearance: AppearanceSettings) throws {
        var merged = loadAppearanceDictionary()
        for (k, v) in appearance.dictionary { merged[k] = v }
        let data = try JSONSerialization.data(withJSONObject: merged,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configFile, options: .atomic)
    }

    /// 只写新设置（`settings.json`）。
    ///
    /// **读-改-写**：先读现有文件，把已知的几个键改掉，**保留未知字段** ——
    /// 别的版本/别的模块写的字段不该被这里抹掉。
    func saveNewSettings(_ settings: AppSettings) throws {
        // 写盘前的保险：**现有文件已损坏 → 先备份**。
        //
        // 以前 `backupCorruptSettingsFile()` 只有测试在调，生产保存路径从来不调 ——
        // 一个损坏的 settings.json 被新内容**直接覆盖**，原始的坏文件就没了，
        // 用户既没得看、也没得恢复。README 里写的「损坏会备份」当时是假的。
        //
        // 正常文件**不产生**备份（这里只在确认损坏时才动手）。
        if settingsFileExists && readSettingsObject(recordDiagnostics: false) == nil {
            if let backup = backupCorruptSettingsFile() {
                NSLog("[DesktopTimetable] settings.json 已损坏，原文件已备份到 %@",
                      backup.lastPathComponent)
            }
        }
        var obj = readSettingsObject(recordDiagnostics: false) ?? [:]
        obj["schemaVersion"] = Self.currentSchemaVersion
        // 每个分组内部也做合并：别的版本写进来的未知键不该被这里抹掉。
        obj["reminder"] = merging(obj["reminder"], with: settings.reminder.jsonObject)
        obj["periods"] = merging(obj["periods"], with: settings.periods.jsonObject)
        obj["notes"] = merging(obj["notes"], with: settings.notes.jsonObject)
        obj["pet"] = merging(obj["pet"], with: settings.pet.jsonObject)
        obj["dayPanel"] = merging(obj["dayPanel"], with: settings.dayPanel.jsonObject)
        let data = try JSONSerialization.data(withJSONObject: obj,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsFile, options: .atomic)
    }

    /// 把已知键合并进旧分组字典，保留旧字典里的未知键。
    private func merging(_ old: Any?, with known: [String: Any]) -> [String: Any] {
        var out = (old as? [String: Any]) ?? [:]
        for (k, v) in known { out[k] = v }
        return out
    }

    /// 读-改-写：保存前先读最新文件，只改调用方负责的字段。
    ///
    /// 这样别的窗口/模块刚改过的值不会被这里的陈旧副本覆盖掉。
    ///
    /// - Parameter mutate: 只改自己负责的字段。
    /// - Returns: 写盘后的最终设置。
    @discardableResult
    func update(_ mutate: (inout AppSettings) -> Void) throws -> AppSettings {
        var current = load()
        mutate(&current)
        try save(current)
        return current
    }

    /// 备份损坏的 `settings.json`（写盘前调用）。
    @discardableResult
    func backupCorruptSettingsFile() -> URL? {
        guard settingsFileIsCorrupt else { return nil }
        return BackupFile.copy(source: settingsFile, into: backupsDirectory,
                               prefix: "settings-corrupt-", suffix: ".json")
    }
}
