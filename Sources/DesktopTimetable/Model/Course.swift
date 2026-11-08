import Foundation

// MARK: - 课程来源

/// 一门课是怎么来的 —— 「覆盖导入」时决定它该不该被自动覆盖 / 删除。
///
/// - `imported`：从课表文件导入，且之后没被用户改过 → 覆盖语义下会被导入内容更新。
/// - `manual`：用户在 app 里新增 → 永远默认保留。
/// - `unknown`：旧数据（没有来源字段）或来源不明 → **一律按保护处理**，
///   宁可多问一句，也不能静默删掉用户的课。
enum CourseOrigin: String, Codable, Equatable {
    case imported
    case manual
    case unknown
}

// MARK: - 课程

/// 一节课在课表网格里的位置与内容。
///
/// `courseID` 课程身份：同一门课的**所有上课时间**共用一个 UUID 字符串。
/// 课程级字段：`name` / `code`；上课时间级字段：`day` / `block` / `teacher` / `loc` / `weeks`。
/// 老师不参与课程身份。
///
/// `day`   1...7（周一...周日）
/// `block` 0...4（`Course.blockRange`），每 2 节课一个 block，网格共 10 行
struct Course: Codable, Equatable, Hashable {

    /// `block` 的合法范围 —— **唯一真源**。
    ///
    /// 网格只有 10 行（`TimetableState.maxBlock`），也就是 5 个 block。
    /// 以前 `FieldParse` 放到 `0...5`（能解析出「晚上」那两节），`ImportPlanner` 只放 `0...4`，
    /// 注释又写 `0...5` —— 三处不一致，后果是 JSON 导入能带进 `block == 5` 的课：
    /// 能写盘、能进统计，但卡片上永远看不见（网格没有第 11–12 行）。
    /// 现在统一按 0...4，放宽范围要同时改网格行数、时段表和 CSS，不能只改校验。
    static let blockRange = 0...4

    /// 课程身份（UUID 字符串）。同一门课的每条上课时间记录都带同一个值。
    var courseID: String = ""

    var day: Int = 1
    var block: Int = 0
    var name: String = ""
    var teacher: String = ""
    var loc: String = ""
    var code: String = ""

    /// 课程自己的颜色（`#rrggbb`）。
    ///
    /// - `nil` = **自动**：按课名查表（`ColorHex.byName`），改名颜色跟着变；
    /// - 有值 = 用户在编辑器里挑的预设色，**改名颜色不变**。
    ///
    /// 这是**课程级字段**：同一 `courseID` 的所有上课时间共享同一个值。
    /// 非法值在解码时按 `nil` 处理（绝不因为一个坏颜色让整张课表读不出来）。
    var colorHex: String? = nil

    /// 只用于显示，**永远由 `weeks` 重新生成**（见 `refreshWeeksLabel()`）。
    var weeksLabel: String = ""

    /// 上课周次。**唯一事实来源**。
    var weeks: [Int] = []

    /// 来源标记：导入 / 用户新增 / 来源不明（旧数据）。默认 `.imported` ——
    /// 只有「解析导入文件」这条路径才会用到默认值，旧数据解码时会被显式设成 `.unknown`。
    var origin: CourseOrigin = .imported

    /// 用户是否改过这门课（改过课名 / 时间 / 地点 / 加了一节都算）。
    var userModified: Bool = false

    /// 用户动过的课（新增或改过）。
    var isUserTouched: Bool { origin == .manual || userModified }

    /// 覆盖导入时**必须保护**的课：用户新增、用户改过、来源不明（旧数据）。
    /// 默认选择里绝不允许自动删除或静默覆盖它们。
    var isProtected: Bool { origin != .imported || userModified }

    /// 课程来源的展示文案（差异页 / 设置面板统一用它，别各写一套）。
    var originLabel: String {
        switch origin {
        case .manual:
            return "你新增"
        case .unknown:
            return "旧数据（来源未知）"
        case .imported:
            return userModified ? "你修改过" : "导入"
        }
    }

    // MARK: 解码

    /// 解码时的可读错误（由 ScheduleStore 转成界面提示）。
    enum DecodeError: LocalizedError, Equatable {
        case missingName
        case invalidDay(String)
        case invalidBlock(String)
        case invalidWeeks(String)

        var errorDescription: String? {
            switch self {
            case .missingName:
                return "缺少课程名（name）"
            case .invalidDay(let raw):
                return "星期无效（\(raw)），应为 1–7 或「周四」「星期四」这类写法"
            case .invalidBlock(let raw):
                return "节次无效（\(raw)），应为 0–\(Course.blockRange.upperBound) 或「第5-6节」这类写法"
            case .invalidWeeks(let raw):
                return "周次无效（\(raw)），应为 [1,2,3] 或「1-3,5-6(单)」这类写法"
            }
        }
    }

    /// 严格解码：
    ///   · `day` 认 Int 和「周四」「星期四」这类字符串；
    ///   · `weeks` 认 [Int] 和「1-3,5-6(单)」这类字符串；
    ///   · 非法数据抛可读错误，**不静默回落**成 day=1 / weeks=[]。
    ///   · `weeksLabel` 一律以 `weeks` 为准重新生成。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        courseID = (try? c.decodeIfPresent(String.self, forKey: .courseID)) ?? ""

        guard let rawName = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil,
              !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodeError.missingName
        }
        self.name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

        let dayInt = try? c.decodeIfPresent(Int.self, forKey: .day)
        let dayStr = try? c.decodeIfPresent(String.self, forKey: .day)
        guard let day = FieldParse.day(int: dayInt ?? nil, string: dayStr ?? nil) else {
            throw DecodeError.invalidDay(describe(dayInt ?? nil, dayStr ?? nil))
        }
        self.day = day

        let blockInt = try? c.decodeIfPresent(Int.self, forKey: .block)
        let blockStr = try? c.decodeIfPresent(String.self, forKey: .block)
        guard let block = FieldParse.block(int: blockInt ?? nil, string: blockStr ?? nil) else {
            throw DecodeError.invalidBlock(describe(blockInt ?? nil, blockStr ?? nil))
        }
        self.block = block

        teacher = (try? c.decodeIfPresent(String.self, forKey: .teacher)) ?? ""
        loc = (try? c.decodeIfPresent(String.self, forKey: .loc)) ?? ""
        code = (try? c.decodeIfPresent(String.self, forKey: .code)) ?? ""

        // 颜色（后加的字段）：**缺失 = 自动**，非法值也当自动。
        // 颜色坏掉绝不能让整张课表读不出来。
        colorHex = ColorHex.normalized((try? c.decodeIfPresent(String.self, forKey: .colorHex)) ?? nil)

        // weeks：字段缺省 = 没有周次（由上层扩成全学期并给出提示）；
        // 字段存在但写法不认 = 非法数据，抛错。
        if c.contains(.weeks) {
            let rawInt = try? c.decodeIfPresent([Int].self, forKey: .weeks)
            let rawStr = try? c.decodeIfPresent(String.self, forKey: .weeks)
            if let r = rawInt {
                guard r.allSatisfy({ $0 >= 1 }) else {
                    throw DecodeError.invalidWeeks(r.map(String.init).joined(separator: ","))
                }
                weeks = r.sorted()
            } else if let s = rawStr {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = WeekSpec.expand(trimmed).sorted()
                // 给了字符串却解析不出任何周次 = 非法数据（空串视为「没写周次」）
                if parsed.isEmpty && !trimmed.isEmpty {
                    throw DecodeError.invalidWeeks(s)
                }
                weeks = parsed
            } else {
                throw DecodeError.invalidWeeks("无法识别")
            }
        } else {
            weeks = []
        }

        // 来源字段（后加的字段）：**缺失 = 旧数据 = unknown**，绝不能因此解码失败。
        // 旧版 app 写出的文件里没有这两个键，用户升级后第一次打开必须照常读出课程。
        if let raw = (try? c.decodeIfPresent(String.self, forKey: .origin)) ?? nil,
           let parsed = CourseOrigin(rawValue: raw) {
            origin = parsed
        } else {
            origin = .unknown
        }
        userModified = ((try? c.decodeIfPresent(Bool.self, forKey: .userModified)) ?? nil) ?? false

        weeksLabel = WeekSpec.format(Set(weeks))
    }

    init(day: Int = 1, block: Int = 0, name: String = "", teacher: String = "",
         loc: String = "", code: String = "", courseID: String = "",
         weeksLabel: String = "", weeks: [Int] = [],
         origin: CourseOrigin = .imported, userModified: Bool = false,
         colorHex: String? = nil) {
        self.day = day
        self.block = block
        self.name = name
        self.teacher = teacher
        self.loc = loc
        self.code = code
        self.courseID = courseID
        self.weeks = weeks
        self.origin = origin
        self.userModified = userModified
        // 存进去之前先规范化：非法值当自动（nil），不往磁盘写脏数据。
        self.colorHex = ColorHex.normalized(colorHex)
        self.weeksLabel = weeksLabel.isEmpty ? WeekSpec.format(Set(weeks)) : weeksLabel
    }

    /// 从字典构造（读取 schedule_data.json 时用）。
    ///
    /// 严格：缺课名 / 星期非法 / 节次非法 / 周次写法不认 → 抛 `DecodeError`。
    /// `weeks` 字段存在但为空数组 → 视为「没写周次」（上层扩成全学期并提示）。
    init(dictionary dict: [String: Any]) throws {
        let rawName = dict["name"] as? String ?? ""
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DecodeError.missingName }
        self.name = name

        guard let day = FieldParse.day(dict["day"]) else {
            throw DecodeError.invalidDay(describeValue(dict["day"]))
        }
        self.day = day

        guard let block = FieldParse.block(dict["block"]) else {
            throw DecodeError.invalidBlock(describeValue(dict["block"]))
        }
        self.block = block

        self.courseID = (dict["courseID"] as? String) ?? ""
        self.teacher = (dict["teacher"] as? String) ?? ""
        self.loc = (dict["loc"] as? String) ?? ""
        self.code = (dict["code"] as? String) ?? ""

        // 颜色：缺失或非法 = 自动（nil）。坏颜色绝不让整张课表读不出来。
        self.colorHex = ColorHex.normalized((dict["colorHex"] as? String) ?? (dict["color"] as? String))

        // 旧数据没有来源字段 → unknown（按保护处理）；不能因为缺字段就抛错。
        self.origin = (dict["origin"] as? String).flatMap(CourseOrigin.init(rawValue:)) ?? .unknown
        if let b = dict["userModified"] as? Bool {
            self.userModified = b
        } else if let n = dict["userModified"] as? NSNumber {
            self.userModified = n.boolValue
        } else {
            self.userModified = false
        }

        if let raw = dict["weeks"], !(raw is NSNull) {
            guard let list = FieldParse.weeks(raw) else {
                throw DecodeError.invalidWeeks(describeValue(raw))
            }
            guard list.allSatisfy({ $0 >= 1 }) else {
                throw DecodeError.invalidWeeks(list.map(String.init).joined(separator: ","))
            }
            self.weeks = list.sorted()
        } else {
            self.weeks = []
        }

        self.weeksLabel = WeekSpec.format(Set(self.weeks))
    }

    // MARK: 周次

    /// 这节课在指定周是否上课。
    ///
    /// `week` 为 nil 表示「全部周次」，一律为真。
    /// 这是**唯一**的「这周上不上」判断入口 —— 卡片、网页、设置面板、冲突检测都走它。
    func isActive(in week: Int?) -> Bool {
        guard let week else { return true }
        return weeks.contains(week)
    }

    /// 周次标签由 `weeks` 重新生成（`weeks` 是唯一事实来源）。
    mutating func refreshWeeksLabel() {
        weeksLabel = WeekSpec.format(Set(weeks))
    }

    /// 上课时间字段（同一 courseID 的所有记录里，只有这组字段逐条不同）。
    var sessionFields: (day: Int, block: Int, teacher: String, loc: String, weeks: [Int]) {
        (day, block, teacher, loc, weeks)
    }

    // MARK: - 展示

    /// 去掉地点里的校区后缀，用于窄格子里的简写。
    var briefLoc: String {
        let cleaned = loc
            .replacingOccurrences(of: "(学校本部)", with: "")
            .replacingOccurrences(of: "(新校区)", with: "")
        let parts = cleaned.components(separatedBy: " / ")
        return parts.count > 1 ? parts[0] + " 等" : parts[0]
    }

    /// 多位教师时只显示第一个 + 「等」。
    var briefTeacher: String {
        let parts = teacher.components(separatedBy: "/")
        return parts.count > 1 ? parts[0] + " 等" : parts[0]
    }

    private func describe(_ intValue: Int?, _ strValue: String?) -> String {
        if let s = strValue { return s }
        if let n = intValue { return String(n) }
        return "缺失"
    }

    private func describeValue(_ v: Any?) -> String {
        guard let v else { return "缺失" }
        if let s = v as? String { return s }
        if let arr = v as? [Any] { return "[" + arr.map { String(describing: $0) }.joined(separator: ",") + "]" }
        return String(describing: v)
    }
}

// MARK: - 课表常量

enum Schedule {
    /// 一节课的时间（每 2 节合成一个 block，网格里画 10 行）。
    ///
    /// 默认值来自 `PeriodSettings.defaults`；用户在设置面板里改完后由
    /// `applyPeriodTimes(_:)` 覆盖。**只改钟点，节数固定 10 节。**
    private(set) static var periods: [PeriodTime] = PeriodSettings.defaults

    /// 应用用户自定义的作息时间（非法配置自动退回默认值）。
    static func applyPeriodTimes(_ times: [PeriodTime]) {
        periods = PeriodSettings.sanitize(times)
    }

    static let dayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    /// 学期总周数的**缺省值**。真正的学期总周数在 `SemesterConfig.maxWeek`，
    /// 由 semester.json 提供；这里只作为没有配置时的兜底。
    static let defaultMaxWeek = 16

    /// 一个 block 的时间范围，如 "08:00–09:35"。
    static func timeRange(block: Int) -> String {
        guard block * 2 + 1 < periods.count else { return "" }
        return "\(periods[block * 2].start)–\(periods[block * 2 + 1].end)"
    }

    /// "08:00" → 480（当天零点起的分钟数）。
    static func minutes(_ hhmm: String) -> Int {
        let p = hhmm.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return 0 }
        return h * 60 + m
    }
}
