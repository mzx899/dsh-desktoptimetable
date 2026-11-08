import Foundation

/// 单周临时覆盖的纯逻辑：判定占用、构造覆盖记录、渲染查询。
///
/// 全部是纯函数，不碰 UI、不碰磁盘，方便单测。
enum WeekOverrideLogic {

    // MARK: - 判定

    /// 该格上的「占用课」：同一格、不同 courseID 的所有课程。
    ///
    /// 同一门课的其它上课时间**不算**占用 —— 那是「自己」；
    /// 而同一门课同格重复是硬错误（`CourseEdit.duplicateSlot` 管）。
    ///
    /// - Parameter ownCourseID: 正在编辑的那门课（新增时传 nil = 谁都算占用）。
    static func occupyingCourses(day: Int, block: Int, courses: [Course],
                                  ownCourseID: String?) -> [Course] {
        courses.filter { c in
            c.day == day && c.block == block
                && (ownCourseID == nil || c.courseID != ownCourseID)
        }
    }

    /// 占用课里与所选周次**有交集**的（真冲突 —— 那一周真的有课在上课）。
    static func conflicting(_ occupying: [Course], weeks: [Int]) -> [Course] {
        occupying.filter { ScheduleConflicts.weeksOverlap($0.weeks, weeks) }
    }

    /// 占用课里与所选周次**没有交集**的（非本周课 —— 只在别的周上课）。
    static func nonOverlapping(_ occupying: [Course], weeks: [Int]) -> [Course] {
        occupying.filter { !ScheduleConflicts.weeksOverlap($0.weeks, weeks) }
    }

    /// 这一格在这个周次**有没有课**（全学期范围，不限周次）。
    ///
    /// 决定「进不进全部周次」：整格从没上过课 → 新课是普通课，进 `courses`；
    /// 整格有课 → 新课只能是临时覆盖，不进 `courses`，
    /// 否则同一个格子在「全部周次」视图里会挤两门课（用户说的「否则会冲突」）。
    static func slotHasAnyCourse(day: Int, block: Int, courses: [Course]) -> Bool {
        courses.contains { $0.day == day && $0.block == block }
    }

    // MARK: - 构造

    /// 构造一条覆盖记录。
    ///
    /// 颜色从草稿带进来 —— 覆盖课要在网格里用自己的颜色画，
    /// 不能因为「写成覆盖」就退回按课名的自动色。
    static func makeOverride(day: Int, block: Int, weeks: [Int], draft: CourseDraft,
                             courseID: String,
                             restored: WeekOverride.RestoredSession?) -> WeekOverride {
        WeekOverride(day: day, block: block, weeks: weeks.sorted(),
                     name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                     teacher: draft.teacher, loc: draft.loc, code: draft.code,
                     courseID: courseID, restored: restored,
                     colorHex: draft.colorHex)
    }

    // MARK: - 占用情况

    /// 一个格子的占用情况 —— 保存时要过的**两道关**。
    struct SlotCollision {
        /// 在所选周次里**真的在上课**的课 → 第一道关：警告。
        var realConflicts: [Course] = []
        /// 在所选周次里**都不上课**的课（非本周课）→ 第二道关：提醒。
        var nonOverlapping: [Course] = []

        /// 这个格子上**有没有别的课**。
        ///
        /// 决定这门课进不进 `courses`：
        ///   · 没有 → 整格从没上过课 → 新课是普通课，进 `courses`（全部周次视图看得见）；
        ///   · 有 → 新课只能是临时覆盖，不进 `courses`（全部周次视图看不见）——
        ///     否则同一个格子在「全部周次」视图里会挤两门课（用户说的「否则会冲突」）。
        var hasOtherCourse: Bool { !realConflicts.isEmpty || !nonOverlapping.isEmpty }
    }

    /// 一次保存要过的两道关（纯函数，可单测）。
    static func collision(day: Int, block: Int, weeks: [Int],
                          courses: [Course], ownCourseID: String?) -> SlotCollision {
        let occ = occupyingCourses(day: day, block: block,
                                   courses: courses, ownCourseID: ownCourseID)
        return SlotCollision(realConflicts: conflicting(occ, weeks: weeks),
                             nonOverlapping: nonOverlapping(occ, weeks: weeks))
    }

    // MARK: - 写盘

    /// 写入一条覆盖记录，同时处理课程表的变化。
    ///
    /// 两件事：
    ///   1. 同格的**旧覆盖**如果移走过原课，那条原课要**放回** `courses`
    ///      （新覆盖接管这一格，旧覆盖的原课不该跟着消失）；
    ///   2. 新覆盖自己移走的原课（`restored`）要**从** `courses` 里拿走
    ///      —— 覆盖期间它在 `courses` 里不存在，只活在覆盖记录里。
    ///
    /// 同一格只保留一条覆盖记录。
    static func writeOverride(_ ov: WeekOverride,
                              into overrides: [WeekOverride],
                              courses: [Course]) -> (courses: [Course], overrides: [WeekOverride]) {
        var cs = courses
        if let old = overrides.first(where: { $0.day == ov.day && $0.block == ov.block }),
           let r = old.restored {
            cs.append(r.asCourse())
        }
        if let r = ov.restored {
            cs = cs.filter { !($0.courseID == r.courseID && $0.day == r.day && $0.block == r.block) }
        }
        let rest = overrides.filter { !($0.day == ov.day && $0.block == ov.block) }
        return (cs, rest + [ov])
    }

    /// 删除一条覆盖记录（撤销覆盖）。
    ///
    /// 覆盖里移走的原课放回 `courses` → 那一格恢复成原来的课；
    /// 没有原课（新增的课）→ 这门课彻底消失。
    static func removeOverride(day: Int, block: Int,
                               from overrides: [WeekOverride],
                               courses: [Course]) -> (courses: [Course], overrides: [WeekOverride]) {
        guard let old = overrides.first(where: { $0.day == day && $0.block == block }) else {
            return (courses, overrides)
        }
        var cs = courses
        if let r = old.restored {
            cs.append(r.asCourse())
        }
        return (cs, overrides.filter { !($0.day == day && $0.block == block) })
    }

    /// 把一次保存算成「新的课表 + 新的覆盖记录」（纯函数）。
    ///
    /// 走的是**覆盖**这条路 —— 也就是「这个时间段上已经有别的课」的情况：
    ///   · 课程级字段（课名 / 代码）同步到同 courseID 的其它记录；
    ///   · 改已有课 → 那条记录从 `courses` 里移出去（存进覆盖的 `restored`），
    ///     撤销覆盖时再放回来；
    ///   · 新增的课 → 只活在覆盖记录里，`courses` 一个字不动。
    ///
    /// 覆盖**不进** `courses`：否则「全部周次」视图里那个格子会挤两门课。
    static func makeOverrideSave(draft: CourseDraft, scope: CourseEditScope,
                                  courses: [Course],
                                  overrides: [WeekOverride]) -> (courses: [Course], overrides: [WeekOverride]) {
        var cs = courses
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var courseID = scope.courseID

        // 课程级字段（含颜色）同步到同 courseID 的其它记录
        let color = ColorHex.normalized(draft.colorHex)
        if !courseID.isEmpty {
            for i in cs.indices where cs[i].courseID == courseID {
                cs[i].name = name
                cs[i].code = draft.code
                cs[i].colorHex = color
            }
        }

        // 编辑已有课 → 那条记录从 `courses` 里移出去
        var restored: WeekOverride.RestoredSession?
        if case .edit(let id, let day, let block) = scope,
           let taken = CourseEdit.takeSession(courseID: id, day: day, block: block, courses: cs) {
            cs = taken.courses
            restored = WeekOverride.RestoredSession(taken.session)
        } else if courseID.isEmpty {
            courseID = UUID().uuidString
        }

        let ov = makeOverride(day: draft.day, block: draft.block, weeks: draft.weeks,
                              draft: draft, courseID: courseID, restored: restored)
        return writeOverride(ov, into: overrides, courses: cs)
    }

    // MARK: - 查询

    /// 某格在某周的覆盖记录。
    ///
    /// 全部周次视图（`week == nil`）**没有**覆盖 → 返回 nil。
    static func override(day: Int, block: Int, week: Int?,
                         in overrides: [WeekOverride]) -> WeekOverride? {
        guard let week else { return nil }
        return overrides.first { $0.day == day && $0.block == block && $0.applies(to: week) }
    }

    /// 某格在任意周次的覆盖记录（不过滤周次）。
    static func override(day: Int, block: Int, in overrides: [WeekOverride]) -> WeekOverride? {
        overrides.first { $0.day == day && $0.block == block }
    }

    /// 某个周次里被覆盖「占住」的格子（`"day-block"`）——
    /// 这些格子里的原课在这一周被遮住（只显示覆盖课）。
    static func coveredSlots(week: Int?, overrides: [WeekOverride]) -> Set<String> {
        guard let week else { return [] }
        return Set(overrides.filter { $0.applies(to: week) }.map { "\($0.day)-\($0.block)" })
    }

    /// 覆盖记录里涉及的所有周次（排序去重）。
    static func weeksCovered(by overrides: [WeekOverride]) -> [Int] {
        Array(Set(overrides.flatMap { $0.weeks })).sorted()
    }
}
