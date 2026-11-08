import Foundation

// MARK: - 草稿

/// 编辑器里的一份「课程 + 上课时间」草稿。
///
/// 课程级字段：`name` / `code` / `colorHex`；上课时间级字段：`day` / `block` / `teacher` / `loc` / `weeks`。
///
/// `colorHex` 是**课程级**颜色：`nil` = 自动（按课名配色），有值 = 用户挑的预设色。
struct CourseDraft: Equatable {
    var name: String = ""
    var code: String = ""
    var teacher: String = ""
    var loc: String = ""
    var day: Int = 1
    var block: Int = 0
    var weeks: [Int] = []
    /// 课程级颜色（`#rrggbb`）；`nil` = 自动（按课名）。
    var colorHex: String? = nil
}

// MARK: - 编辑范围

/// 一次编辑的作用范围（决定保存时改哪些记录）。
enum CourseEditScope: Equatable {
    /// 新增一门课（含第一节课）。courseID 新生成。
    case create(day: Int, block: Int)
    /// 编辑课程：
    ///   · 课程级字段（课名 / 代码）→ 同步到该 courseID 的**所有**记录；
    ///   · 上课时间级字段 → 只改 `day` / `block` 指定的那一条记录。
    case edit(courseID: String, day: Int, block: Int)
    /// 添加一个上课时间：课程级字段只读（沿用已有课程），新增一条记录，复用 courseID。
    case addSession(courseID: String)

    /// 这个范围里的课程身份（新建时为空 = 会生成新 ID）。
    var courseID: String {
        switch self {
        case .create: return ""
        case .edit(let id, _, _): return id
        case .addSession(let id): return id
        }
    }
}

// MARK: - 校验错误

enum CourseEditError: LocalizedError, Equatable {
    case emptyName
    case invalidDay(Int)
    case invalidBlock(Int)
    case emptyWeeks
    case weekOutOfRange(Int)
    /// 同一门课同一格重复上课时间。
    case duplicateSlot(courseName: String)
    /// 批量编辑时，表单里一个时段都不剩。
    case emptySessions
    /// 批量编辑时，表单里有两个时段落在同一格。
    case duplicateSlotInEditor(firstSlot: Int, secondSlot: Int, day: Int, block: Int)
    /// 正在编辑的那一次上课已经不存在了（记录被别处删掉 / 课表已变）。
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "课名不能为空"
        case .invalidDay(let d):
            return "星期必须是 1–7（周一…周日），当前是 \(d)"
        case .invalidBlock(let b):
            return "节次必须在 0–4（第 1–10 节），当前是 \(b)"
        case .emptyWeeks:
            return "周次不能为空（用 1-16 或 1-3,5-6(单) 这类写法）"
        case .weekOutOfRange(let w):
            return "周次 \(w) 超出学期总周数"
        case .duplicateSlot(let name):
            return "「\(name)」在同一时间已经有上课记录了"
        case .emptySessions:
            return "至少要保留一个上课时间"
        case .duplicateSlotInEditor(let first, let second, let day, let block):
            let dayName = (1...7).contains(day) ? Schedule.dayNames[day - 1] : "第 \(day) 天"
            let time = (Course.blockRange).contains(block)
                ? "第 \(block * 2 + 1)–\(block * 2 + 2) 节（\(Schedule.timeRange(block: block))）"
                : "第 \(block) 节"
            return "时段 \(first + 1) 和时段 \(second + 1) 都是\(dayName)\(time)，同一门课不能在同一时间重复"
        case .sessionNotFound:
            return "这次上课的记录已经不存在了（可能刚被删掉），请重新打开编辑器"
        }
    }
}

// MARK: - 编辑计划（纯逻辑）

/// 右键编辑器的数据层：校验 → 应用。
///
/// 纯函数，不碰 UI，方便单元测试。
enum CourseEdit {

    // MARK: 校验

    /// 校验草稿。
    ///
    /// - Parameters:
    ///   - scope: 编辑范围（决定重复检查要排除哪条记录）。
    ///   - courses: 当前课表全部记录。
    ///   - maxWeek: 学期总周数（周次上界）。
    static func validate(draft: CourseDraft,
                         scope: CourseEditScope,
                         courses: [Course],
                         maxWeek: Int) -> [CourseEditError] {
        var errors: [CourseEditError] = []

        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { errors.append(.emptyName) }

        if !(1...7).contains(draft.day) { errors.append(.invalidDay(draft.day)) }
        if !(0...4).contains(draft.block) { errors.append(.invalidBlock(draft.block)) }

        if draft.weeks.isEmpty {
            errors.append(.emptyWeeks)
        } else if let over = draft.weeks.filter({ $0 > maxWeek || $0 < 1 }).min() {
            errors.append(.weekOutOfRange(over))
        }

        // 正在编辑的那一次上课还在不在？
        // 找不到 → 课表在编辑期间变了（比如那条记录刚被删掉），明确报错，
        // 别让它走到「保存成功但什么都没改」。
        if case .edit(let courseID, let day, let block) = scope {
            let exists = courses.contains {
                $0.courseID == courseID && $0.day == day && $0.block == block
            }
            if !exists { errors.append(.sessionNotFound) }
        }

        // 同一门课同一格重复 → 拒绝保存
        if errors.isEmpty, let dup = duplicateSlot(draft: draft, scope: scope, courses: courses) {
            errors.append(.duplicateSlot(courseName: dup))
        }
        return errors
    }

    /// 草稿落到的 (day, block) 上，是否已经有同一门课的**其它**记录。
    ///
    /// 关键：`scope` 里的 day/block 必须是**用户点的那一次上课**的坐标。
    /// 如果 scope 指向的是同一门课的另一个上课时间，这里排除的就不是它 ——
    /// 用户点的那次会被当成「重复」，保存时直接被拒（这就是之前
    /// 「我明明改的就是这门课，却提示该时间段已有课程」的根因）。
    private static func duplicateSlot(draft: CourseDraft,
                                      scope: CourseEditScope,
                                      courses: [Course]) -> String? {
        switch scope {
        case .create:
            return nil                      // 新课新 courseID，不可能重复
        case .edit(let courseID, let day, let block):
            // 排除正在编辑的这一条（它自己不算重复）
            let others = courses.filter {
                $0.courseID == courseID && !($0.day == day && $0.block == block)
            }
            return others.first { $0.day == draft.day && $0.block == draft.block }?.name
        case .addSession(let courseID):
            return courses.first {
                $0.courseID == courseID && $0.day == draft.day && $0.block == draft.block
            }?.name
        }
    }

    // MARK: 冲突

    /// 与草稿冲突的其它课程（不同 courseID、同一格、周次有交集）。
    ///
    /// 同门课同一格的重复不算冲突（那是校验错误，直接拒绝保存）。
    ///
    /// **自己永远不跟自己冲突**：`scope.courseID` 为空表示新建（谁都冲突），
    /// 非空表示编辑/追加 —— 这时同一门课的所有上课时间都被排除，
    /// 包括**正在编辑的那一次**。
    static func conflicts(draft: CourseDraft,
                          scope: CourseEditScope,
                          courses: [Course]) -> [Course] {
        guard !draft.weeks.isEmpty else { return [] }
        let ownID = scope.courseID
        return courses.filter { c in
            guard c.courseID != ownID else { return false }
            guard c.day == draft.day && c.block == draft.block else { return false }
            return ScheduleConflicts.weeksOverlap(c.weeks, draft.weeks)
        }
    }

    // MARK: 应用

    /// 把草稿应用到课表，返回新的课程数组。
    ///
    /// - Throws: `CourseEditError`（校验不通过时）。
    static func apply(draft: CourseDraft,
                      scope: CourseEditScope,
                      courses: [Course],
                      maxWeek: Int) throws -> [Course] {
        let errors = validate(draft: draft, scope: scope, courses: courses, maxWeek: maxWeek)
        if let first = errors.first { throw first }

        var list = courses
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 课程级颜色：`nil` = 自动。非法值先规范化掉，不往磁盘写脏数据。
        let color = ColorHex.normalized(draft.colorHex)

        switch scope {
        case .create:
            // 用户自己在 app 里新增的课 → 来源 manual。覆盖导入时默认保留，永不自动删除。
            var c = Course(day: draft.day, block: draft.block, name: name,
                           teacher: draft.teacher, loc: draft.loc, code: draft.code,
                           courseID: UUID().uuidString, weeks: draft.weeks,
                           origin: .manual, userModified: false,
                           colorHex: color)
            c.refreshWeeksLabel()
            list.append(c)

        case .edit(let courseID, let day, let block):
            // 用户改过这门课 → 维护来源标记。
            //   · imported → 该 courseID 的所有记录 userModified = true（课程级字段是共享的，
            //     只有一条记录被标成「改过」会让差异页对同一门课给出两种来源）；
            //   · manual   → 保持 manual；
            //   · unknown  → 保持 unknown（本来就是保护的，不需要额外标记）。
            let origin = list.first { $0.courseID == courseID }?.origin ?? .unknown
            // 课程级字段：同步到所有同 courseID 的记录
            for i in list.indices where list[i].courseID == courseID {
                list[i].name = name
                list[i].code = draft.code
                list[i].colorHex = color
                if origin == .imported { list[i].userModified = true }
            }
            // 上课时间级字段：只改当前这一条（day/block 是用户点的那一次）
            var hit = false
            for i in list.indices where list[i].courseID == courseID
                && list[i].day == day && list[i].block == block {
                hit = true
                list[i].teacher = draft.teacher
                list[i].loc = draft.loc
                list[i].day = draft.day
                list[i].block = draft.block
                list[i].weeks = draft.weeks
            }
            // 记录已经不在了 → 明确报错，不要静默保存成「什么都没改」
            if !hit { throw CourseEditError.sessionNotFound }

        case .addSession(let courseID):
            // 课程级字段沿用已有课程；上课时间级字段用草稿
            let template = courses.first { $0.courseID == courseID }
            let origin = template?.origin ?? .unknown
            // 给已有课程加一节 = 用户改过这门课。
            //   · imported → 该 courseID 的所有记录（含新加的这条）标成 userModified；
            //   · manual / unknown → 保持原样。
            let modified = (origin == .imported)
            if modified {
                for i in list.indices where list[i].courseID == courseID {
                    list[i].userModified = true
                }
            }
            // 颜色是课程级字段：添加上课时间时课名 / 代码只读，但颜色可改
            // → 同 courseID 的所有记录一起改成草稿里的颜色。
            for i in list.indices where list[i].courseID == courseID {
                list[i].colorHex = color
            }
            var c = Course(day: draft.day, block: draft.block,
                           name: template?.name ?? name,
                           teacher: draft.teacher, loc: draft.loc,
                           code: template?.code ?? draft.code,
                           courseID: courseID, weeks: draft.weeks,
                           origin: origin,
                           userModified: modified || (template?.userModified ?? false),
                           colorHex: color)
            c.refreshWeeksLabel()
            list.append(c)
        }

        for i in list.indices { list[i].refreshWeeksLabel() }
        return list
    }

    // MARK: 删除

    /// 删除某一次上课（只删这一条记录）。
    static func deleteSession(courseID: String,
                               day: Int,
                               block: Int,
                               courses: [Course]) -> [Course] {
        courses.filter {
            !($0.courseID == courseID && $0.day == day && $0.block == block)
        }
    }

    /// 删除整门课程（该 courseID 的所有记录）。
    static func deleteCourse(courseID: String, courses: [Course]) -> [Course] {
        courses.filter { $0.courseID != courseID }
    }

    /// 某门课有几条上课时间记录。
    static func sessionCount(courseID: String, courses: [Course]) -> Int {
        courses.filter { $0.courseID == courseID }.count
    }

    /// 把某一次上课从课表里**取出来**（转成单周临时覆盖时用）。
    ///
    /// 覆盖不是「加一门课」，而是「这个格子在这几周归另一门课」——
    /// 所以原来那条记录要从 `courses` 里移出去（移出后它只在覆盖记录里活着）。
    ///
    /// - Returns: (剩下的课表, 被取出的那条)；找不到 → nil。
    static func takeSession(courseID: String,
                            day: Int,
                            block: Int,
                            courses: [Course]) -> (courses: [Course], session: Course)? {
        guard let s = courses.first(where: {
            $0.courseID == courseID && $0.day == day && $0.block == block
        }) else { return nil }
        let rest = courses.filter {
            !($0.courseID == courseID && $0.day == day && $0.block == block)
        }
        return (rest, s)
    }

    // MARK: 周次文本

    /// 解析周次文本（"1-16" / "1-3,5-6(单)"）。
    static func parseWeeks(_ text: String) -> [Int] {
        WeekSpec.expand(text).sorted()
    }

    /// 周次集合 → 文本（"1-16" / "1-3,5-6"）。
    static func formatWeeks(_ weeks: [Int]) -> String {
        WeekSpec.format(Set(weeks))
    }

    /// 周次预览文案："共 16 周：1-16"。
    static func weeksPreview(_ weeks: [Int]) -> String {
        let sorted = weeks.sorted()
        guard !sorted.isEmpty else { return "共 0 周" }
        return "共 \(sorted.count) 周：\(WeekSpec.format(Set(sorted)))"
    }
}
