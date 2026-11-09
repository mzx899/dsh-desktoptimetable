import Foundation

/// 一条日记。
///
/// 日记**不进 EventKit**（系统日历 / 提醒事项里没有「日记」这个概念），
/// 存在 app 自己的数据目录里：`<数据目录>/diary.json`。
struct DiaryEntry: Codable, Equatable {
    /// 稳定标识（删除 / 修改都靠它）。
    var id: String
    /// 属于哪一天，`yyyy-MM-dd`（按**本地时区**算，和日期覆盖层的列一致）。
    var date: String
    /// 标题（可以空 —— 空标题在列表里显示「（未命名）」）。
    var title: String
    /// 正文（可多行）。
    var body: String
    /// 时间，`HH:mm`；空串 = 没写具体时间。
    var time: String
    /// 最后一次修改的时刻（排序 / 「最近写的」用）。
    var updatedAt: TimeInterval
    /// 软删除时刻（nil = 还在）。
    ///
    /// 删除先进「最近删除」（保留 30 天），过期为自动清掉 ——
    /// 用户要求「日记可以恢复，也可以全部删除」，时限 30 天。
    var deletedAt: TimeInterval? = nil
}

/// 日记的读写（JSON 小文件，整体读写即可 —— 单条最多几百字，没到需要数据库的量级）。
///
/// 设计取舍：
///   · **按天存放**（`date` 字段），日期覆盖层点哪天就取哪天；
///   · 文件损坏时**不覆盖**：解析失败返回空、但下次写入前会先备份一份
///     `.corrupt-<时间戳>`，用户的内容不会因为一次解析异常被静默清掉；
///   · 所有写入走「写临时文件 → 原子替换」，中途退出不会留下半个 JSON。
final class DiaryStore {

    /// 数据目录（测试时由 `DT_DATA_DIR` 指向临时目录）。
    private let directory: URL
    private let fileURL: URL

    /// 日期格式化（只用一种格式，避免时区 / locale 漂移）。
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 把日期转成键（`yyyy-MM-dd`）。
    static func dateKey(_ date: Date) -> String { dateFormatter.string(from: date) }

    /// 把键转回当天零点。
    static func date(fromKey key: String) -> Date? { dateFormatter.date(from: key) }

    init(directory: URL = AppPaths.supportDirectory) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("diary.json")
    }

    // MARK: - 读

    /// 加载全部条目（按日期倒序、同一天内按时间升序）。
    func all() -> [DiaryEntry] {
        loadRaw().filter { $0.deletedAt == nil }.sorted { a, b in
            if a.date != b.date { return a.date > b.date }
            let ta = a.time.isEmpty ? "99:99" : a.time
            let tb = b.time.isEmpty ? "99:99" : b.time
            if ta != tb { return ta < tb }
            return a.updatedAt < b.updatedAt
        }
    }

    /// 某一天的日记（按时间升序；没写时间的排最后）。
    func entries(on date: String) -> [DiaryEntry] {
        all().filter { $0.date == date }.sorted { a, b in
            let ta = a.time.isEmpty ? "99:99" : a.time
            let tb = b.time.isEmpty ? "99:99" : b.time
            if ta != tb { return ta < tb }
            return a.updatedAt < b.updatedAt
        }
    }

    /// 一共几条（设置里显示数量用，只算未删除的）。
    func count() -> Int { all().count }

    /// 最近删除里还能恢复的那些（30 天内，最近的在前）。
    func deletedEntries() -> [DiaryEntry] {
        let limit = Date().timeIntervalSince1970 - Self.trashRetention
        return loadRaw()
            .filter { entry in
                guard let at = entry.deletedAt else { return false }
                return at >= limit
            }
            .sorted { ($0.deletedAt ?? 0) > ($1.deletedAt ?? 0) }
    }

    /// 回收站保留多久（秒）。30 天。
    static let trashRetention: TimeInterval = 30 * 24 * 60 * 60

    // MARK: - 写

    @discardableResult
    func add(date: String, title: String, body: String, time: String) throws -> DiaryEntry {
        var items = loadRaw()
        let entry = DiaryEntry(id: UUID().uuidString,
                               date: date,
                               title: title,
                               body: body,
                               time: time,
                               updatedAt: Date().timeIntervalSince1970)
        items.append(entry)
        try save(items)
        return entry
    }

    /// 修改。返回是否找到了这一条（找不到就当没改，不报错）。
    @discardableResult
    func update(id: String, title: String, body: String, time: String,
                date: String? = nil) throws -> Bool {
        var items = loadRaw()
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        items[idx].title = title
        items[idx].body = body
        items[idx].time = time
        if let date { items[idx].date = date }
        items[idx].updatedAt = Date().timeIntervalSince1970
        try save(items)
        return true
    }

    /// 删除 = **软删除**（进「最近删除」，30 天内可恢复）。
    @discardableResult
    func delete(id: String) throws -> Bool {
        var items = loadRaw()
        guard let idx = items.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else {
            return false
        }
        items[idx].deletedAt = Date().timeIntervalSince1970
        try save(items)
        return true
    }

    /// 从「最近删除」里恢复。
    @discardableResult
    func restore(id: String) throws -> Bool {
        var items = loadRaw()
        guard let idx = items.firstIndex(where: { $0.id == id && $0.deletedAt != nil }) else {
            return false
        }
        items[idx].deletedAt = nil
        try save(items)
        return true
    }

    /// 彻底删掉一条（「最近删除」里再删一次）。
    @discardableResult
    func deletePermanently(id: String) throws -> Bool {
        var items = loadRaw()
        let before = items.count
        items.removeAll { $0.id == id && $0.deletedAt != nil }
        guard items.count != before else { return false }
        try save(items)
        return true
    }

    /// 清空「最近删除」。
    @discardableResult
    func emptyTrash() throws -> Int {
        var items = loadRaw()
        let before = items.count
        items.removeAll { $0.deletedAt != nil }
        try save(items)
        return before - items.count
    }

    /// 过期清理：删掉 30 天以上的「最近删除」（读 / 写时顺手跑一次）。
    private func purgeExpired(_ items: [DiaryEntry]) -> (items: [DiaryEntry], changed: Bool) {
        let limit = Date().timeIntervalSince1970 - Self.trashRetention
        let kept = items.filter { ($0.deletedAt ?? .greatestFiniteMagnitude) >= limit }
        return (kept, kept.count != items.count)
    }

    /// 删除某一天的全部（日期覆盖层「清空这一天」用）。
    @discardableResult
    func deleteAll(on date: String) throws -> Int {
        var items = loadRaw()
        let now = Date().timeIntervalSince1970
        var removed = 0
        for idx in items.indices where items[idx].date == date && items[idx].deletedAt == nil {
            items[idx].deletedAt = now
            removed += 1
        }
        if removed > 0 { try save(items) }
        return removed
    }

    // MARK: - 落盘

    private struct FileShape: Codable {
        var version: Int = 1
        var entries: [DiaryEntry] = []
    }

    private func loadRaw() -> [DiaryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let shape = try JSONDecoder().decode(FileShape.self, from: data)
            let purged = purgeExpired(shape.entries)
            if purged.changed { try? save(purged.items) }
            return purged.items
        } catch {
            // 解析失败：**先备份再当空**，别让下一次写入把用户的内容覆盖掉。
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = directory.appendingPathComponent("diary.corrupt-\(stamp).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            DiagLog.info("日记文件解析失败，已备份到 \(backup.lastPathComponent)：\(error)")
            return []
        }
    }

    private func save(_ entries: [DiaryEntry]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shape = FileShape(version: 1, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(shape)
        let tmp = directory.appendingPathComponent("diary.json.tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }
    }
}
