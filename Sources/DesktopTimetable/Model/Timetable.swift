import Foundation

/// 一份课表。
///
/// 阶段 3 引入多课表后，「课程 + 学期 + 名字」作为一个整体被叫做课表。
/// 桌面卡片上显示的一切（标题、副标题、周次、课程、学期日期）都来自当前课表。
///
/// 课程身份用 `courseID`（见 `Course`），同一门课的所有上课时间共用一个 ID。
///
/// 以后的笔记按 `timetableID + courseID` 存：
/// 本期还不实现笔记，但 courseID 机制已经留好，
/// 删掉整门课时笔记会保留下来、标记为孤立。
struct Timetable: Equatable {
    var id: String
    var name: String
    var subtitle: String
    var createdAt: Date
    var updatedAt: Date
    var semester: SemesterConfig
    var courses: [Course]

    init(id: String = UUID().uuidString,
         name: String,
         subtitle: String = "",
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         semester: SemesterConfig = SemesterConfig(start: Date(),
                                                    maxWeek: SemesterConfig.defaultMaxWeek),
         courses: [Course] = []) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.semester = semester
        self.courses = courses
    }

    /// 学期总周数（含数据超出的兜底）。
    var effectiveMaxWeek: Int { semester.effectiveMaxWeek(for: courses) }

    /// 课程门数（按 courseID 去重）。
    var courseCount: Int {
        Set(courses.map { $0.courseID }).count
    }
}

// MARK: - 元数据

/// 课表元数据（存 `meta.json`）。
///
/// 只放描述性的东西；课程数据在同目录的 `schedule_data.json`，
/// 学期配置在 `semester.json`。
struct TimetableMeta: Codable, Equatable {
    var id: String
    var name: String
    var subtitle: String
    var createdAt: Date
    var updatedAt: Date

    init(id: String, name: String, subtitle: String = "",
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 转换成一份完整的课表（还没填课程和学期）。
    func toTimetable() -> Timetable {
        Timetable(id: id, name: name, subtitle: subtitle,
                  createdAt: createdAt, updatedAt: updatedAt)
    }

    /// 编码用的字典（`meta.json`）。
    func jsonObject() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "subtitle": subtitle,
            "createdAt": ISO8601DateFormatter.timetableStamp.string(from: createdAt),
            "updatedAt": ISO8601DateFormatter.timetableStamp.string(from: updatedAt),
        ]
    }

    /// 从字典解析；缺字段时用兜底值，不抛错。
    static func from(json obj: [String: Any]) -> TimetableMeta? {
        guard let id = obj["id"] as? String, !id.isEmpty else { return nil }
        let name = (obj["name"] as? String) ?? "未命名课表"
        let subtitle = (obj["subtitle"] as? String) ?? ""
        let now = Date()
        let created = (obj["createdAt"] as? String)
            .flatMap { ISO8601DateFormatter.timetableStamp.date(from: $0) } ?? now
        let updated = (obj["updatedAt"] as? String)
            .flatMap { ISO8601DateFormatter.timetableStamp.date(from: $0) } ?? created
        return TimetableMeta(id: id, name: name, subtitle: subtitle,
                             createdAt: created, updatedAt: updated)
    }
}

// MARK: - 索引

/// 课表索引（存 `timetables/index.json`）。
///
/// ```json
/// { "activeID": "…", "items": [ {id,name,subtitle,updatedAt}, … ] }
/// ```
struct TimetableIndex: Codable, Equatable {
    var activeID: String?
    var items: [TimetableMeta] = []
    /// 旧版数据是否已经迁移过。
    ///
    /// 没有这个标记的话，删掉全部课表之后 `needsLegacyMigration` 会重新变成
    /// true，根目录的旧文件会被「复活」成一份新课表 —— 用户明明刚删干净。
    var legacyMigrated: Bool = false

    init(activeID: String? = nil, items: [TimetableMeta] = [], legacyMigrated: Bool = false) {
        self.activeID = activeID
        self.items = items
        self.legacyMigrated = legacyMigrated
    }

    /// 编码用的字典。
    func jsonObject() -> [String: Any] {
        var obj: [String: Any] = ["items": items.map { $0.jsonObject() }]
        obj["activeID"] = activeID ?? NSNull()
        obj["legacyMigrated"] = legacyMigrated
        return obj
    }

    /// 从字典解析；解析失败返回空索引（不抛错）。
    static func from(json obj: [String: Any]) -> TimetableIndex {
        let items = (obj["items"] as? [[String: Any]] ?? [])
            .compactMap { TimetableMeta.from(json: $0) }
        var active = obj["activeID"] as? String
        // activeID 必须指向真实存在的课表
        if let a = active, !items.contains(where: { $0.id == a }) {
            active = nil
        }
        let migrated = (obj["legacyMigrated"] as? Bool) ?? false
        return TimetableIndex(activeID: active, items: items, legacyMigrated: migrated)
    }
}

// MARK: - ISO8601 扩展

extension ISO8601DateFormatter {
    /// 课表元数据用的时间戳格式（精确到秒，带时区）。
    static let timetableStamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()
}
