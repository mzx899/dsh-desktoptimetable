import Foundation

/// 课表存储层：**唯一**的课表读写入口。
///
/// AppDelegate、设置面板、右键编辑器都必须通过它读写，
/// 不能各自拼路径 —— 那样迟早会出现两份数据对不上的情况。
///
/// 目录结构：
/// ```
/// Application Support/DesktopTimetable/
///   config.json                 // 外观设置，保持全局，不动
///   timetables/
///     index.json                // { activeID, items: [{id,name,subtitle,updatedAt}] }
///     <uuid>/
///       meta.json               // { id, name, subtitle, createdAt, updatedAt }
///       schedule_data.json      // 课程数组
///       semester.json           // { start, maxWeek }
///       backups/
///         schedule_data-YYYYMMDD-HHmmss.json
/// ```
///
/// 旧版（阶段 1/2）的 `schedule_data.json` / `semester.json` 躺在数据目录根下，
/// 首次运行时自动迁移成第一份课表；迁移前先备份，迁移成功后**保留**备份。
final class TimetableStore {

    // MARK: - 错误

    enum StoreError: LocalizedError {
        case notFound(String)
        case writeFailed(String)
        case invalidIndex

        var errorDescription: String? {
            switch self {
            case .notFound(let id): return "找不到课表（\(id)）"
            case .writeFailed(let m): return "写入失败：\(m)"
            case .invalidIndex: return "课表索引损坏"
            }
        }
    }

    // MARK: - 路径

    /// 数据根目录（`~/Library/Application Support/DesktopTimetable`）。
    let rootDirectory: URL
    /// 外观配置文件（全局，不属于任何课表）。
    var configFile: URL { rootDirectory.appendingPathComponent("config.json") }
    /// 课表根目录。
    var timetablesDirectory: URL { rootDirectory.appendingPathComponent("timetables", isDirectory: true) }
    /// 课表索引。
    var indexFile: URL { timetablesDirectory.appendingPathComponent("index.json") }

    /// 某份课表的目录。
    func directory(for id: String) -> URL {
        timetablesDirectory.appendingPathComponent(id, isDirectory: true)
    }

    /// 某份课表的元数据文件。
    func metaFile(for id: String) -> URL {
        directory(for: id).appendingPathComponent("meta.json")
    }

    /// 某份课表的课程文件。
    func coursesFile(for id: String) -> URL {
        directory(for: id).appendingPathComponent("schedule_data.json")
    }

    /// 某份课表的学期文件。
    func semesterFile(for id: String) -> URL {
        directory(for: id).appendingPathComponent("semester.json")
    }

    /// 某份课表的备份目录。
    func backupsDirectory(for id: String) -> URL {
        directory(for: id).appendingPathComponent("backups", isDirectory: true)
    }

    // MARK: - 生命周期

    init(rootDirectory: URL = AppPaths.supportDirectory) {
        self.rootDirectory = rootDirectory
        try? FileManager.default.createDirectory(at: timetablesDirectory,
                                                withIntermediateDirectories: true)
    }

    // MARK: - 索引

    /// 读索引。文件不存在 → 空索引；损坏 → 空索引（不抛，交给上层提示）。
    func loadIndex() -> TimetableIndex {
        guard let data = try? Data(contentsOf: indexFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TimetableIndex()
        }
        return TimetableIndex.from(json: obj)
    }

    /// 索引文件**存在但读不出来**（损坏）。
    ///
    /// 「不存在」和「损坏」必须分开看：
    /// 以前两种情况都返回空索引，于是 `legacyMigrated` 也变回 false ——
    /// 如果根目录的旧文件还在，`needsLegacyMigration` 会再次为 true，
    /// 下次启动就把旧数据**再迁移一份**，变成两份重复课表。
    var indexIsCorrupt: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: indexFile.path) else { return false }
        guard let data = try? Data(contentsOf: indexFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return true }
        // `items: []` 是合法的：删光所有课表之后索引本来就该长这样。
        // 只有「items 键缺失 / 类型不对」或「有 items 但一条都解析不出来」才算损坏。
        guard let rawItems = obj["items"] as? [[String: Any]] else { return true }
        if rawItems.isEmpty { return false }
        return TimetableIndex.from(json: obj).items.isEmpty
    }

    /// 把损坏的索引备份走（避免下次又坏一次没法查）。
    @discardableResult
    func backupCorruptIndex() -> URL? {
        guard indexIsCorrupt else { return nil }
        let dir = timetablesDirectory.appendingPathComponent("backups", isDirectory: true)
        return BackupFile.copy(source: indexFile, into: dir,
                               prefix: "index-corrupt-", suffix: ".json")
    }

    /// 删掉 `id` 之后，`activeID` 会变成哪一个（与 `delete(id:)` 的实际行为一致）。
    ///
    /// 确认框里的提示必须和真正切换到的那一份一致 ——
    /// 以前提示写的是 `others[0]`（`allMetas()` 按更新时间倒序的第一份），
    /// 而 `delete()` 返回的是 `index.items.first`（索引顺序），
    /// 两者经常不是同一份课表，用户看到的提示是错的。
    func nextActiveIDAfterDeleting(id: String) -> String? {
        let index = loadIndex()
        guard index.items.contains(where: { $0.id == id }) else { return nil }
        if index.activeID == id {
            return index.items.first { $0.id != id }?.id
        }
        return index.activeID
    }

    /// 写索引（原子写）。
    func saveIndex(_ index: TimetableIndex) throws {
        try FileManager.default.createDirectory(at: timetablesDirectory,
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: index.jsonObject(),
                                              options: [.prettyPrinted, .sortedKeys])
        try writeAtomically(data, to: indexFile)
    }

    /// 全部课表的元数据（按更新时间倒序，最近的在最前）。
    func allMetas() -> [TimetableMeta] {
        loadIndex().items.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 当前课表 ID。
    ///
    /// 索引里的 `activeID` 是权威来源；UserDefaults 只存一份**提示**，
    /// 用来在索引损坏时尽量猜回上次用的课表。课程数据一律不进 UserDefaults。
    var activeID: String? {
        let index = loadIndex()
        if let id = index.activeID, index.items.contains(where: { $0.id == id }) {
            return id
        }
        // 索引不可用 → 退回到 UserDefaults 里的提示
        if let hint = UserDefaults.standard.string(forKey: Self.activeIDDefaultsKey) {
            let fm = FileManager.default
            if fm.fileExists(atPath: metaFile(for: hint).path) { return hint }
        }
        return index.items.first?.id
    }

    /// UserDefaults 里 activeID 的键名。
    static let activeIDDefaultsKey = "DesktopTimetable.activeTimetableID"

    /// 设置当前课表。
    func setActive(_ id: String) throws {
        var index = loadIndex()
        guard index.items.contains(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }
        index.activeID = id
        try saveIndex(index)
        UserDefaults.standard.set(id, forKey: Self.activeIDDefaultsKey)
    }

    // MARK: - 迁移（旧单课表 → 第一份课表）

    /// 旧版数据在根目录下的课程文件。
    var legacyCoursesFile: URL { rootDirectory.appendingPathComponent("schedule_data.json") }
    /// 旧版数据在根目录下的学期文件。
    var legacySemesterFile: URL { rootDirectory.appendingPathComponent("semester.json") }

    /// 是否需要做旧数据迁移（根目录有旧文件，但还没有课表）。
    var needsLegacyMigration: Bool {
        let fm = FileManager.default
        let index = loadIndex()
        // 已经迁移过就不再迁移（删光课表后也不该把旧文件「复活」）
        guard !index.legacyMigrated else { return false }
        // 索引损坏 → **不要迁移**。
        // 以前这两种情况都返回空索引，`legacyMigrated` 也变 false，
        // 于是根目录的旧文件会被再迁移一份，变成两份重复课表。
        // 现在索引坏了就停手：先备份 + 提示用户，别制造重复数据。
        if indexIsCorrupt { return false }
        let hasLegacy = fm.fileExists(atPath: legacyCoursesFile.path)
            || fm.fileExists(atPath: legacySemesterFile.path)
        return hasLegacy && index.items.isEmpty
    }

    /// 把旧版单课表数据迁移成第一份课表。
    ///
    /// - 迁移前**备份**旧文件（保留在 `backups/` 旁边的 legacy 备份里，不删）。
    /// - 旧数据里已有的 courseID **原样保留**；没有的才按 CourseGrouper 生成。
    /// - 幂等：迁移成功后 `needsLegacyMigration` 为 false，再调一次什么都不做。
    @discardableResult
    func migrateLegacyIfNeeded(defaultName: String = "我的课表",
                                defaultSubtitle: String = "") throws -> Timetable? {
        guard needsLegacyMigration else { return nil }

        let fm = FileManager.default
        let id = UUID().uuidString
        let dir = directory(for: id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // ---- 迁移前备份旧文件（成功迁移后也保留）----
        let legacyBackupDir = rootDirectory.appendingPathComponent("backups", isDirectory: true)
        try? fm.createDirectory(at: legacyBackupDir, withIntermediateDirectories: true)
        let stamp = Self.backupStamp()
        for src in [legacyCoursesFile, legacySemesterFile] where fm.fileExists(atPath: src.path) {
            let dst = legacyBackupDir.appendingPathComponent("legacy-\(src.lastPathComponent)-\(stamp)")
            try? fm.copyItem(at: src, to: dst)
        }

        // ---- 搬数据 ----
        if fm.fileExists(atPath: legacyCoursesFile.path) {
            try fm.copyItem(at: legacyCoursesFile, to: coursesFile(for: id))
        }
        if fm.fileExists(atPath: legacySemesterFile.path) {
            try fm.copyItem(at: legacySemesterFile, to: semesterFile(for: id))
        }

        // ---- 元数据 ----
        let meta = TimetableMeta(id: id, name: defaultName, subtitle: defaultSubtitle)
        try writeMeta(meta)

        // ---- 索引 ----
        let index = TimetableIndex(activeID: id, items: [meta], legacyMigrated: true)
        try saveIndex(index)
        UserDefaults.standard.set(id, forKey: Self.activeIDDefaultsKey)

        // ---- 旧文件保留在原地（不删），只是不再被读取 ----
        return try load(id)
    }

    // MARK: - 仓库

    /// 某份课表的数据仓库（课程 + 学期）。
    ///
    /// 课程数据的读写**只有这一条路径** —— 和阶段 1/2 一样，
    /// 迁移、备份、原子写都交给 `ScheduleRepository`，
    /// 避免出现「课表结构层写一份、课程层写另一份」的情况。
    func repository(for id: String) -> ScheduleRepository {
        // 课程数据在课表自己的目录里，外观配置仍然是全局的那一份
        ScheduleRepository(store: ScheduleStore(directory: directory(for: id),
                                                configDirectory: rootDirectory))
    }

    /// 当前课表的数据仓库。
    func activeRepository() -> ScheduleRepository? {
        activeID.map { repository(for: $0) }
    }

    /// 外观配置用的 store —— `config.json` 是全局的，所有课表共用一份。
    var configStore: ScheduleStore {
        ScheduleStore(directory: rootDirectory, configDirectory: rootDirectory)
    }

    // MARK: - 增删改查

    /// 新建一份课表。
    ///
    /// - Parameter courses: 课程数据（默认空）。传入的记录**原样保存**，
    ///   调用方负责保证 courseID 已经分配好（新建课表要用全新 ID）。
    @discardableResult
    func create(name: String, subtitle: String = "",
                courses: [Course] = [],
                semester: SemesterConfig? = nil) throws -> Timetable {
        let id = UUID().uuidString
        let now = Date()
        let meta = TimetableMeta(id: id, name: name, subtitle: subtitle,
                                 createdAt: now, updatedAt: now)
        let dir = directory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeMeta(meta)

        let timetable = Timetable(id: id, name: name, subtitle: subtitle,
                                  createdAt: now, updatedAt: now,
                                  semester: semester ?? SemesterConfig(start: now),
                                  courses: courses)
        // `save` 内部会把元数据同步进索引，这里不要再追加一次
        try save(timetable)

        return timetable
    }

    /// 重命名（只改 name / subtitle，**不改 id、不改 courseID**）。
    /// 重命名课表。
    ///
    /// 课表名**允许重名**，但为了和「新建 / 导入」的行为一致，
    /// 重名时自动加后缀（「课表」→「课表 2」）——
    /// 以前新建会加后缀、重命名不会，同一个项目里两套规则。
    /// 改名到和原来一样的名字不会变成「课表 2」（去重时会排除它自己）。
    func rename(id: String, name: String, subtitle: String) throws {
        var index = loadIndex()
        guard let pos = index.items.firstIndex(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }
        let newName = uniqueName(name, excluding: id)
        index.items[pos].name = newName
        index.items[pos].subtitle = subtitle
        index.items[pos].updatedAt = Date()
        try writeMeta(index.items[pos])
        try saveIndex(index)
    }

    /// 重名自动加后缀（「课表」→「课表 2」→「课表 3」）。
    ///
    /// **新建 / 导入 / 重命名三条路共用这一套规则** ——
    /// 以前只有导入那条路去重，新建和重命名都不管，结果同名的课表能有好几份。
    ///
    /// - Parameter excluding: 参与去重时要忽略的那一份（重命名时是它自己）。
    func uniqueName(_ name: String, excluding id: String? = nil) -> String {
        let existing = Set(allMetas().filter { $0.id != id }.map { $0.name })
        if !existing.contains(name) { return name }
        var i = 2
        while existing.contains("\(name) \(i)") { i += 1 }
        return "\(name) \(i)"
    }

    /// 删除一份课表。
    ///
    /// 删除前**备份整个课表目录**到 `timetables/backups/`。
    /// - Returns: 删除后应该切换到的课表 ID（nil = 进入空课表状态）。
    @discardableResult
    func delete(id: String) throws -> String? {
        let fm = FileManager.default
        var index = loadIndex()
        guard index.items.contains(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }

        // ---- 删除前备份整个目录 ----
        let dir = directory(for: id)
        if fm.fileExists(atPath: dir.path) {
            let backupRoot = timetablesDirectory.appendingPathComponent("backups", isDirectory: true)
            try? fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
            let target = backupRoot.appendingPathComponent(
                "timetable-\(id)-\(Self.backupStamp())", isDirectory: true)
            try? fm.copyItem(at: dir, to: target)
        }

        try? fm.removeItem(at: dir)
        index.items.removeAll { $0.id == id }
        if index.activeID == id {
            index.activeID = index.items.first?.id
        }
        try saveIndex(index)

        if let newActive = index.activeID {
            UserDefaults.standard.set(newActive, forKey: Self.activeIDDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeIDDefaultsKey)
        }
        return index.activeID
    }

    /// 读一份课表的完整内容。
    ///
    /// 课程数据的读取走 `ScheduleRepository` —— 这样每份课表都会自动做
    /// courseID 迁移和周次补全（阶段 1 的逻辑，不用在这里重写一遍）。
    func load(_ id: String) throws -> Timetable {
        try loadDetailed(id).timetable
    }

    /// 读一份课表的完整内容 **+ 加载诊断**（错误 / 提示 / 异常）。
    ///
    /// 以前只有 `load(id:)`，它把 `ScheduleRepository.LoadResult` 里的
    /// error / notices / anomalies **全丢了** —— 上层（课表管理、导入决策）看到的是
    /// 一个「干净的空课表」，于是：
    ///   · 数据损坏时，导入决策会走「当前课表为空 → 直接导入」的路径，把坏文件覆盖掉；
    ///   · 「周次缺失，已按全学期处理」这类提示用户永远看不到。
    func loadDetailed(_ id: String) throws -> (timetable: Timetable, result: ScheduleRepository.LoadResult) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: metaFile(for: id).path) else {
            throw StoreError.notFound(id)
        }
        var meta: TimetableMeta
        var metaBroken = false
        if let data = try? Data(contentsOf: metaFile(for: id)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = TimetableMeta.from(json: obj) {
            meta = m
        } else {
            // meta.json 损坏 → 退回「未命名课表」，但要留个提示，别悄悄吞掉
            metaBroken = true
            meta = TimetableMeta(id: id, name: "未命名课表")
        }

        var loaded = repository(for: id).load()
        if metaBroken {
            loaded.notices.insert("课表信息文件已损坏，暂用「未命名课表」显示", at: 0)
        }

        let timetable = Timetable(id: meta.id, name: meta.name, subtitle: meta.subtitle,
                                  createdAt: meta.createdAt, updatedAt: meta.updatedAt,
                                  semester: loaded.semester, courses: loaded.courses)
        return (timetable, loaded)
    }

    /// 保存一份课表的完整内容（课程 + 学期）。
    ///
    /// 课程和学期的读写交给 `ScheduleRepository`（备份 + 原子写都在那里），
    /// 这里只管课表自己的元数据和索引。
    func save(_ timetable: Timetable) throws {
        let fm = FileManager.default
        let dir = directory(for: timetable.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // ---- 课程 + 学期（走统一的数据层）----
        let repo = repository(for: timetable.id)
        try repo.save(timetable.courses)
        try repo.saveSemester(timetable.semester)

        // ---- 元数据（updatedAt 跟着走）----
        let meta = TimetableMeta(id: timetable.id, name: timetable.name,
                                 subtitle: timetable.subtitle,
                                 createdAt: timetable.createdAt,
                                 updatedAt: Date())
        try writeMeta(meta)

        // ---- 索引同步 ----
        var index = loadIndex()
        if let pos = index.items.firstIndex(where: { $0.id == timetable.id }) {
            index.items[pos] = meta
        } else {
            index.items.append(meta)
        }
        try saveIndex(index)
    }

    /// 只改名称/副标题（不碰课程数据）。
    func saveMetaOnly(_ timetable: Timetable) throws {
        let meta = TimetableMeta(id: timetable.id, name: timetable.name,
                                 subtitle: timetable.subtitle,
                                 createdAt: timetable.createdAt,
                                 updatedAt: Date())
        try writeMeta(meta)
        var index = loadIndex()
        if let pos = index.items.firstIndex(where: { $0.id == timetable.id }) {
            index.items[pos] = meta
        } else {
            index.items.append(meta)
        }
        try saveIndex(index)
    }

    // MARK: - 备份

    /// 某份课表的备份列表（新的在前）。
    ///
    /// **唯一实现**在 `ScheduleStore`（每个课表目录一份 `backups/`）。
    /// 以前这里自己又写了一套 `backupCourses` / `backupSemester` / `pruneBackups`，
    /// 但实际写盘路径走的是 `repository(for:).save(...)` → `ScheduleStore.backupCourses()`，
    /// 那套代码除了测试没人调用 —— 两套实现、同一批文件，早晚分叉。
    /// 现在这里只做转发。
    func listBackups(for id: String) -> [URL] {
        repository(for: id).store.listBackups()
    }

    // MARK: - 私有

    private func writeMeta(_ meta: TimetableMeta) throws {
        let dir = directory(for: meta.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: meta.jsonObject(),
                                              options: [.prettyPrinted, .sortedKeys])
        try writeAtomically(data, to: metaFile(for: meta.id))
    }

    /// 原子写：先写临时文件，再替换目标。
    private func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        try? fm.removeItem(at: tmp)
        try data.write(to: tmp)
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
    }

    /// 备份时间戳（`Asia/Shanghai`，毫秒精度）。
    ///
    /// 以前用系统默认时区 + 秒精度，和 `ScheduleStore` 的实现是两套，
    /// 同一台机器改过时区就会产生两套命名。现在统一走 `BackupFile`。
    static func backupStamp() -> String {
        BackupFile.stamp()
    }
}
